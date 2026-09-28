"""Phase 5 deterministic gate/HTTP tests. AI is a test double, not a real model."""
import http.client
import json
import threading
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch
from urllib.parse import urlencode

import numpy as np
from automatic import AutomaticDetection
from coordination import Coordinator, ProtocolError, ROLES
from meit_ai_adapter import MEITAIAdapter
from server import BridgeServer, METADATA


class GateTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.c = Coordinator(clock=lambda: self.now)
        self.auto = AutomaticDetection(self.c)
        self.devices = {r: {"device_id": str(uuid.uuid4()), "role": r} for r in ROLES}

    def report(self, role="front", rms=-20, ready=True):
        self.c.register(self.devices[role])
        self.c.report_rms({**self.devices[role], "rms_dbfs": rms, "ai_buffer_ready": ready})

    def trigger(self):
        self.auto.set_enabled(True)
        self.auto.observe()
        return self.auto.status()["active_event"]

    def claim(self):
        event = self.auto.active
        return self.auto.claim_audio({**self.devices[event["source"]["role"]], "event_id": event["event_id"]})

    def finish(self, label="siren", danger=True):
        return self.auto.complete(self.claim(), {"label": label, "confidence": .8, "inference_ms": 1, "danger": danger})

    def test_off_by_default_and_stop_blocks_loud_reports(self):
        self.report()
        self.auto.observe()
        self.assertIsNone(self.auto.active)
        self.trigger()
        self.auto.set_enabled(False)
        self.assertEqual(self.auto.last_event["outcome"], "stopped")
        self.assertIsNone(self.c.poll(self.devices["front"])["command"])
        self.now += 4
        self.report()
        self.auto.observe()
        self.assertIsNone(self.auto.active)

    def test_one_device_can_trigger_and_infer_without_direction(self):
        self.report()
        event = self.trigger()
        self.assertEqual(event["source_role"], "front")
        command = self.c.poll(self.devices["front"])["command"]
        self.assertEqual(command["kind"], "infer_snapshot")
        self.assertEqual(command["event_id"], event["event_id"])
        self.assertIsNone(self.c.poll(self.devices["front"])["command"])
        result = self.finish()
        self.assertEqual(result["label"], "siren")
        self.assertEqual(result["direction"], "unknown")
        self.assertFalse(result["haptic"]["queued"])

    def test_four_source_is_loudest_corrected_ready_fresh(self):
        for role, level in zip(ROLES, [-42, -24, -39, -45]):
            self.report(role, level)
        self.c.devices[self.devices["back"]["device_id"]].calibration_offset_db = 20
        self.assertEqual(self.trigger()["source_role"], "back")
        self.assertEqual(self.auto.active["selection"].result["direction"], "back")

    def test_stale_and_unready_sources_excluded(self):
        self.report("left", -5)
        self.now += .6
        self.report("right", -10, False)
        self.report("front", -25)
        self.assertEqual(self.trigger()["source_role"], "front")

    def test_missing_readiness_backward_compatible_but_not_auto_source(self):
        self.c.register(self.devices["front"])
        self.c.report_rms({**self.devices["front"], "rms_dbfs": -10})
        self.assertIsNone(self.trigger())
        with self.assertRaises(ProtocolError):
            self.report(ready="true")

    def test_threshold_and_direction_margin_independent(self):
        self.report("front", -31)
        self.assertIsNone(self.trigger())
        self.report("front", -25)
        self.report("right", -26)
        self.auto.observe()
        self.assertEqual(self.auto.active["selection"].result["direction"], "unknown")

    def test_active_and_cooldown_do_not_retrigger_then_quiet_rearms(self):
        self.report()
        first = self.trigger()["event_id"]
        for _ in range(20):
            self.auto.observe()
        self.assertEqual(self.auto.active["event_id"], first)
        self.finish()
        for step in [.1, 1, 3, 4]:
            self.now += step
            self.report()
            self.auto.observe()
            self.assertIsNone(self.auto.active)
        # Quiet has to be observed continuously, not inferred from offline time.
        for _ in range(5):
            self.now += .2
            self.report(rms=-40)
            self.auto.observe()
        self.assertTrue(self.auto.armed)
        self.report()
        self.auto.observe()
        self.assertNotEqual(self.auto.active["event_id"], first)

    def test_quiet_report_gap_does_not_rearm(self):
        self.report()
        self.trigger()
        self.finish()
        self.now += 4
        self.report(rms=-40)
        self.auto.observe()
        self.now += 4
        self.report(rms=-40)
        self.auto.observe()
        self.assertFalse(self.auto.armed)

    def test_waiting_timeout_expires_command_and_recovers(self):
        self.report()
        event = self.trigger()["event_id"]
        self.now += 3.01
        self.auto.tick()
        self.assertEqual(self.auto.state, "COOLDOWN")
        self.assertEqual(self.auto.last_event["outcome"], "audio_timeout")
        self.assertIsNone(self.c.poll(self.devices["front"])["command"])
        with self.assertRaises(ProtocolError):
            self.auto.claim_audio({**self.devices["front"], "event_id": event})
        self.now += 3.01
        self.auto.tick()
        self.assertEqual(self.auto.state, "IDLE")

    def test_queue_full_fails_bounded_event_without_overwriting_haptic(self):
        for role, level in zip(ROLES, [-40, -20, -45, -42]):
            self.report(role, level)
        self.c.test_haptic()
        self.assertIsNone(self.trigger())
        self.assertEqual(self.auto.last_event["outcome"], "command_unavailable")
        self.assertEqual(self.c.poll(self.devices["right"])["command"]["kind"], "direction_haptic")

    def test_changed_registration_rejects_source(self):
        self.report()
        event = self.trigger()["event_id"]
        self.c.register({**self.devices["front"], "role": "left"})
        with self.assertRaises(ProtocolError):
            self.auto.claim_audio({**self.devices["front"], "event_id": event})

    def test_trigger_direction_survives_later_rms_and_haptic_only_once(self):
        for role, level in zip(ROLES, [-40, -20, -45, -42]):
            self.report(role, level)
        self.trigger()
        for role in ROLES:
            self.report(role, -10 if role == "left" else -40)
        result = self.finish()
        self.assertEqual(self.c.selection().result["direction"], "left")
        self.assertEqual(result["direction"], "right")
        self.assertEqual(result["direction_details"]["devices"]["right"]["rms_dbfs"], -20)
        self.assertTrue(result["haptic"]["queued"])
        command = self.c.poll(self.devices["right"])["command"]
        self.assertEqual(command["kind"], "direction_haptic")
        self.assertEqual(command["event_id"], result["event_id"])
        self.assertIsNone(self.c.poll(self.devices["right"])["command"])

    def test_normal_and_existing_decision_rejection_do_not_haptic(self):
        for label, danger in [("normal", False), ("siren", False)]:
            with self.subTest(label=label):
                self.setUp()
                for role, level in zip(ROLES, [-40, -20, -45, -42]):
                    self.report(role, level)
                self.trigger()
                self.assertFalse(self.finish(label, danger)["haptic"]["queued"])

    def test_stop_during_inference_holds_slot_until_completion_even_after_start(self):
        self.report()
        self.trigger()
        event = self.claim()
        self.auto.set_enabled(False)
        self.auto.set_enabled(True)
        self.auto.observe()
        self.assertEqual(self.auto.active["event_id"], event)
        with self.assertRaises(ProtocolError):
            self.auto.complete(event, {"label": "siren", "danger": True})
        self.assertIsNone(self.auto.active)
        self.assertEqual(self.auto.last_event["outcome"], "stopped")
        self.assertIsNone(self.c.poll(self.devices["front"])["command"])

    def test_stop_removes_pending_auto_haptic(self):
        for role, level in zip(ROLES, [-40, -20, -45, -42]):
            self.report(role, level)
        self.trigger()
        self.assertTrue(self.finish()["haptic"]["queued"])
        self.auto.set_enabled(False)
        self.assertIsNone(self.c.poll(self.devices["right"])["command"])

    def test_configuration_validation(self):
        for kwargs in [{"trigger_dbfs": float("nan")}, {"trigger_dbfs": -100}, {"trigger_dbfs": -97},
                       {"cooldown": 0}, {"audio_timeout": -1}, {"rearm_quiet": float("inf")}]:
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                AutomaticDetection(self.c, **kwargs)


class AutoHTTPTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.adapter = Mock()
        self.output = {"label": "siren", "confidence": .8, "inference_ms": 1, "danger": True}
        self.adapter.infer_auto.return_value = self.output
        self.adapter.infer.return_value = {k: v for k, v in self.output.items() if k != "danger"}
        self.server = BridgeServer(("127.0.0.1", 0), self.adapter, Coordinator(clock=lambda: self.now))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.devices = {r: {"device_id": str(uuid.uuid4()), "role": r} for r in ROLES}
        for message in self.devices.values():
            self.request("POST", "/device/register", message)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, method, path, data=None, headers=None):
        if isinstance(data, bytes):
            body = data
            headers = {"Content-Type": "application/octet-stream", **METADATA, **(headers or {})}
        else:
            body = json.dumps(data).encode() if data is not None else None
            headers = {"Content-Type": "application/json"}
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        try:
            connection.request(method, path, body, headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def report(self, role="front", level=-20):
        return self.request("POST", "/device/rms", {**self.devices[role], "rms_dbfs": level, "ai_buffer_ready": True})

    def trigger(self, four=False):
        if four:
            for role, level in zip(ROLES, [-40, -20, -45, -42]):
                self.report(role, level)
        self.assertEqual(self.request("POST", "/auto/start", {})[0], 200)
        self.report("right" if four else "front")
        status = self.request("GET", "/auto/status")[1]
        event = status["active_event"]
        device = self.devices[event["source_role"]]
        response = self.request("GET", "/device/command?" + urlencode(device))[1]
        self.assertEqual(response["command"]["kind"], "infer_snapshot")
        self.assertTrue(response["auto"]["enabled"])
        return {"X-Event-ID": event["event_id"], "X-Device-ID": device["device_id"], "X-Device-Role": device["role"]}

    def test_invalid_ids_and_duplicate_upload_infer_only_once(self):
        headers = self.trigger()
        for replacement in [{"X-Event-ID": str(uuid.uuid4())}, {"X-Device-ID": str(uuid.uuid4())},
                            {"X-Device-Role": "left"}, {"X-Event-ID": "invalid"}]:
            status, _ = self.request("POST", "/event/audio", bytes(80000), {**headers, **replacement})
            self.assertIn(status, (400, 409))
        self.adapter.infer_auto.assert_not_called()
        with ThreadPoolExecutor(2) as pool:
            futures = [pool.submit(self.request, "POST", "/event/audio", bytes(80000), headers) for _ in range(2)]
            responses = [future.result() for future in futures]
        self.assertEqual(sorted(r[0] for r in responses), [200, 409])
        self.adapter.infer_auto.assert_called_once()
        result = next(r[1] for r in responses if r[0] == 200)
        self.assertEqual(result["direction"], "unknown")
        self.assertFalse(result["haptic"]["queued"])
        self.assertEqual(self.request("POST", "/infer", bytes(80000))[0], 200)
        self.adapter.infer.assert_called_once()  # Manual works during auto cooldown.

    def test_auto_pcm_contract_and_metadata_rejected_before_model(self):
        headers = self.trigger()
        for body, extra in [(bytes(79999), headers), (bytes(80000), {}),
                            (bytes(80000), {**headers, "X-Audio-Sample-Rate": "48000"})]:
            self.assertEqual(self.request("POST", "/event/audio", body, extra)[0], 400)
        self.adapter.infer_auto.assert_not_called()

    def test_auto_inference_does_not_block_http_and_keeps_trigger_direction(self):
        headers = self.trigger(four=True)
        entered, release = threading.Event(), threading.Event()
        def infer(_):
            entered.set()
            if not release.wait(4):
                raise TimeoutError()
            return self.output
        self.adapter.infer_auto.side_effect = infer
        with ThreadPoolExecutor(1) as pool:
            future = pool.submit(self.request, "POST", "/event/audio", bytes(80000), headers)
            try:
                self.assertTrue(entered.wait(2))
                self.now += 1
                for role in ROLES:
                    self.assertEqual(self.report(role, -10 if role == "left" else -40)[0], 200)
                self.assertEqual(self.request("GET", "/health")[0], 200)
                poll = self.request("GET", "/device/command?" + urlencode(self.devices["front"]))
                self.assertEqual(poll[1]["auto"]["state"], "INFERENCING")
                self.assertEqual(self.request("POST", "/event/audio", bytes(80000), headers)[0], 409)
            finally:
                release.set()
            status, result = future.result()
        self.assertEqual(status, 200)
        self.assertEqual(result["direction"], "right")
        self.assertTrue(result["haptic"]["queued"])
        self.adapter.infer_auto.assert_called_once()

    def test_auto_stop_while_waiting_for_model_lock_skips_model(self):
        headers = self.trigger()
        # claim_audio is observed without a polling/sleep race via a test hook.
        claimed = threading.Event()
        original = self.server.automatic.claim_audio
        def claim(metadata):
            result = original(metadata)
            claimed.set()
            return result
        self.server.automatic.claim_audio = claim
        with ThreadPoolExecutor(1) as pool:
            self.server.inference_lock.acquire()
            future = pool.submit(self.request, "POST", "/event/audio", bytes(80000), headers)
            try:
                self.assertTrue(claimed.wait(2))
                self.assertEqual(self.request("POST", "/auto/stop", {})[0], 200)
            finally:
                self.server.inference_lock.release()
            self.assertEqual(future.result()[0], 409)
        self.adapter.infer_auto.assert_not_called()
        self.assertEqual(self.request("GET", "/auto/status")[1]["last_event"]["outcome"], "stopped")

    def test_stop_during_running_model_suppresses_auto_haptic_and_preserves_manual(self):
        headers = self.trigger(four=True)
        entered, release = threading.Event(), threading.Event()
        def infer(_):
            entered.set()
            if not release.wait(4):
                raise TimeoutError()
            return self.output
        self.adapter.infer_auto.side_effect = infer
        with ThreadPoolExecutor(1) as pool:
            future = pool.submit(self.request, "POST", "/event/audio", bytes(80000), headers)
            try:
                self.assertTrue(entered.wait(2))
                self.assertEqual(self.request("POST", "/auto/stop", {})[0], 200)
                self.assertEqual(self.request("GET", "/health")[0], 200)
            finally:
                release.set()
            self.assertEqual(future.result()[0], 409)
        self.adapter.infer_auto.assert_called_once()
        self.assertIsNone(self.request("GET", "/device/command?" + urlencode(self.devices["right"]))[1]["command"])
        self.assertEqual(self.request("POST", "/infer", bytes(80000))[0], 200)
        self.assertEqual(self.request("GET", "/device/command?" + urlencode(self.devices["right"]))[1]["command"]["kind"], "direction_haptic")

    def test_auto_and_manual_share_one_model_lock(self):
        headers = self.trigger()
        entered, release, claimed = threading.Event(), threading.Event(), threading.Event()
        def manual(_):
            entered.set()
            if not release.wait(4):
                raise TimeoutError()
            return self.adapter.infer.return_value
        self.adapter.infer.side_effect = manual
        original = self.server.automatic.claim_audio
        def claim(metadata):
            result = original(metadata)
            claimed.set()
            return result
        self.server.automatic.claim_audio = claim
        with ThreadPoolExecutor(2) as pool:
            first = pool.submit(self.request, "POST", "/infer", bytes(80000))
            self.assertTrue(entered.wait(2))
            second = pool.submit(self.request, "POST", "/event/audio", bytes(80000), headers)
            try:
                self.assertTrue(claimed.wait(2))
                self.adapter.infer_auto.assert_not_called()
                self.assertEqual(self.request("GET", "/health")[0], 200)
            finally:
                release.set()
            self.assertEqual(first.result()[0], 200)
            self.assertEqual(second.result()[0], 200)
        self.adapter.infer_auto.assert_called_once()

    def test_inference_failure_is_sanitized_and_exits_active_state(self):
        headers = self.trigger()
        self.adapter.infer_auto.side_effect = RuntimeError("secret model path")
        status, result = self.request("POST", "/event/audio", bytes(80000), headers)
        self.assertEqual(status, 500)
        self.assertNotIn("secret", json.dumps(result))
        state = self.request("GET", "/auto/status")[1]
        self.assertIsNone(state["active_event"])
        self.assertEqual(state["last_event"]["outcome"], "inference_failed")

    def test_server_service_actions_expires_wait_without_new_rms(self):
        headers = self.trigger()
        self.now += 3.1
        self.server.service_actions()
        self.assertEqual(self.server.automatic.last_event["outcome"], "audio_timeout")
        self.assertEqual(self.request("POST", "/event/audio", bytes(80000), headers)[0], 409)
        self.adapter.infer_auto.assert_not_called()


class AutoAdapterTests(unittest.TestCase):
    def test_reuses_external_judge_probabilities_and_db_without_second_inference(self):
        adapter = MEITAIAdapter.__new__(MEITAIAdapter)
        adapter.np = np
        adapter.root = Path("external-ai").resolve()
        adapter.decision = None
        probs = {"horn": .1, "siren": .7, "crash": .1, "normal": .1}
        adapter.api = SimpleNamespace(CLASSES=list(probs), predict_array=Mock(return_value=(probs, -20)))
        judge = Mock(return_value={"sound_class": "siren"})
        with patch("meit_ai_adapter.importlib.util.find_spec", return_value=SimpleNamespace(origin=str(adapter.root / "decision" / "judge.py"))), \
             patch("meit_ai_adapter.importlib.import_module", return_value=SimpleNamespace(judge=judge)) as imported:
            self.assertTrue(adapter.infer_auto(bytes(80000))["danger"])
            judge.assert_called_once_with(probs, direction=-1, db=-20)
            judge.return_value = None
            self.assertFalse(adapter.infer_auto(bytes(80000))["danger"])
            imported.assert_called_once_with("decision.judge")
        self.assertEqual(adapter.api.predict_array.call_count, 2)
        self.assertNotIn("danger", adapter.infer(bytes(80000)))


if __name__ == "__main__":
    unittest.main()
