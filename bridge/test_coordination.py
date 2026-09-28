"""Deterministic registry tests and concurrent HTTP tests; no phone or model required."""
import http.client
import json
import threading
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import Mock
from urllib.parse import urlencode

from coordination import Coordinator, ProtocolError, ROLES
from server import BridgeServer, METADATA


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.coordinator = Coordinator(clock=lambda: self.now)
        self.messages = {role: {"device_id": str(uuid.uuid4()), "role": role} for role in ROLES}

    def populate(self):
        for role, rms in zip(ROLES, [-42, -24, -39, -45]):
            self.coordinator.register(self.messages[role])
            self.coordinator.report_rms({**self.messages[role], "rms_dbfs": rms})

    def test_registration_idempotence_and_role_change(self):
        message = self.messages["front"]
        self.coordinator.register(message)
        first = self.coordinator.devices[message["device_id"]].registration_id
        self.coordinator.register(message)
        self.assertEqual(self.coordinator.devices[message["device_id"]].registration_id, first)
        self.coordinator.register({**message, "role": "back"})
        self.assertNotEqual(self.coordinator.devices[message["device_id"]].registration_id, first)
        self.assertEqual(len(self.coordinator.devices), 1)

    def test_role_conflict_does_not_overwrite_and_resolves_on_role_change(self):
        front = self.messages["front"]
        competitor = {**self.messages["right"], "role": "front"}
        self.coordinator.register(front)
        with self.assertRaises(ProtocolError) as error:
            self.coordinator.register(competitor)
        self.assertEqual(error.exception.status, 409)
        self.assertEqual(self.coordinator.selection().result["conflict_roles"], ["front"])
        self.assertIn(front["device_id"], self.coordinator.devices)
        self.coordinator.register(self.messages["right"])
        self.assertEqual(self.coordinator.selection().result["conflict_roles"], [])

    def test_incomplete_sets_are_unknown(self):
        for role in ROLES[:3]:
            self.coordinator.register(self.messages[role])
            self.coordinator.report_rms({**self.messages[role], "rms_dbfs": -20})
            state = self.coordinator.selection().result
            self.assertEqual(state["direction"], "unknown")
            self.assertTrue(state["missing_roles"])

    def test_fresh_strongest_role_and_margin(self):
        self.populate()
        result = self.coordinator.selection().result
        self.assertEqual(result["direction"], "right")
        self.assertEqual(result["winner_dbfs"], -24)
        self.assertEqual(result["runner_up_dbfs"], -39)
        self.assertEqual(result["margin_db"], 15)

    def test_margin_tie_and_configurable_threshold(self):
        self.populate()
        for front in [-24, -26]:
            self.coordinator.report_rms({**self.messages["front"], "rms_dbfs": front})
            self.assertEqual(self.coordinator.selection().result["direction"], "unknown")
        self.coordinator.report_rms({**self.messages["front"], "rms_dbfs": -27})
        self.assertEqual(self.coordinator.selection().result["direction"], "right")
        self.coordinator.margin_db = 4
        self.assertEqual(self.coordinator.selection().result["direction"], "unknown")

    def test_stale_rms_excluded_even_with_poll_heartbeat(self):
        self.populate()
        self.now += 0.501
        for message in self.messages.values():
            self.coordinator.poll(message)
        state = self.coordinator.selection().result
        self.assertEqual(state["direction"], "unknown")
        self.assertEqual(set(state["stale_roles"]), set(ROLES))
        self.assertIsNone(state["winner_dbfs"])
        self.assertTrue(all(d["online"] for d in state["devices"].values()))

    def test_offline_owner_can_be_reclaimed(self):
        self.populate()
        old = self.messages["right"]
        self.now += 5.01
        self.assertIn("right", self.coordinator.selection().result["missing_roles"])
        replacement = {"device_id": str(uuid.uuid4()), "role": "right"}
        self.coordinator.register(replacement)
        with self.assertRaises(ProtocolError):
            self.coordinator.poll(old)

    def test_rms_validation_and_role_identity(self):
        message = self.messages["front"]
        self.coordinator.register(message)
        for rms in [float("nan"), float("inf"), -float("inf"), 1, -101, True, "-20", None, 10**1000]:
            with self.subTest(rms=str(rms)[:30]), self.assertRaises(ProtocolError):
                self.coordinator.report_rms({**message, "rms_dbfs": rms})
        with self.assertRaises(ProtocolError):
            self.coordinator.report_rms({**message, "role": "left", "rms_dbfs": -20})
        for rms in [-100, 0]:
            self.coordinator.report_rms({**message, "rms_dbfs": rms})
        with self.assertRaises(ProtocolError):
            self.coordinator.register({"device_id": "invalid", "role": "front"})

    def test_zero_calibration_and_future_offset(self):
        self.populate()
        self.assertTrue(all(d.calibration_offset_db == 0 for d in self.coordinator.devices.values()))
        front = self.coordinator.devices[self.messages["front"]["device_id"]]
        front.calibration_offset_db = 25  # Test-only; no measured offsets are configured by default.
        result = self.coordinator.selection().result
        self.assertEqual(result["direction"], "front")
        self.assertEqual(result["devices"]["front"]["rms_dbfs"], -42)
        self.assertEqual(result["devices"]["front"]["corrected_rms_dbfs"], -17)

    def test_command_bounded_atomic_consume_and_no_duplicate(self):
        self.populate()
        selected = self.coordinator.selection()
        first = self.coordinator.enqueue(selected, "test")
        self.assertTrue(first["queued"])
        self.assertEqual(self.coordinator.enqueue(selected, "test")["reason"], "command_pending")
        with ThreadPoolExecutor(4) as pool:
            responses = list(pool.map(lambda _: self.coordinator.poll(self.messages["right"]), range(4)))
        commands = [r["command"] for r in responses if r["command"]]
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0]["command_id"], first["command_id"])
        self.assertIsNone(self.coordinator.poll(self.messages["front"])["command"])

    def test_expired_command_and_changed_target_not_delivered(self):
        self.populate()
        selected = self.coordinator.selection()
        self.coordinator.enqueue(selected, "test")
        self.now += 2.01
        self.assertIsNone(self.coordinator.poll(self.messages["right"])["command"])
        self.now += 5.01  # Expire from the last poll heartbeat, not the initial registration.
        self.coordinator.register(self.messages["right"])
        self.assertFalse(self.coordinator.enqueue(selected, "test")["queued"])

    def test_conflict_suppresses_queued_command(self):
        self.populate()
        self.coordinator.enqueue(self.coordinator.selection(), "test")
        with self.assertRaises(ProtocolError):
            self.coordinator.register({"device_id": str(uuid.uuid4()), "role": "right"})
        self.assertIsNone(self.coordinator.poll(self.messages["right"])["command"])

    def test_normal_silent_danger_targets_and_unknown_keeps_ai_result(self):
        self.populate()
        base = {"confidence": 0.8, "inference_ms": 1}
        result = self.coordinator.after_inference({**base, "label": "normal"}, self.coordinator.selection())
        self.assertFalse(result["haptic"]["queued"])
        for label in ["horn", "siren", "crash"]:
            result = self.coordinator.after_inference({**base, "label": label}, self.coordinator.selection())
            self.assertTrue(result["haptic"]["queued"])
            self.assertEqual(self.coordinator.poll(self.messages["right"])["command"]["role"], "right")
        self.now += 1
        result = self.coordinator.after_inference({**base, "label": "siren"}, self.coordinator.selection())
        self.assertEqual(result["label"], "siren")
        self.assertEqual(result["direction"], "unknown")
        self.assertFalse(result["haptic"]["queued"])


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.adapter = Mock()
        self.adapter.infer.return_value = {"label": "siren", "confidence": 0.8, "inference_ms": 1}
        self.server = BridgeServer(("127.0.0.1", 0), self.adapter)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.messages = {role: {"device_id": str(uuid.uuid4()), "role": role} for role in ROLES}

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, method, path, data=None, pcm=False):
        body = data if pcm else json.dumps(data).encode() if data is not None else None
        headers = ({"Content-Type": "application/octet-stream", **METADATA} if pcm
                   else {"Content-Type": "application/json"} if body is not None else {})
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        try:
            connection.request(method, path, body, headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def populate(self):
        for role, rms in zip(ROLES, [-42, -24, -39, -45]):
            self.assertEqual(self.request("POST", "/device/register", self.messages[role])[0], 200)
            self.assertEqual(self.request("POST", "/device/rms", {**self.messages[role], "rms_dbfs": rms})[0], 200)

    def test_protocol_registration_conflict_validation_direction_and_command(self):
        self.populate()
        self.assertEqual(self.request("GET", "/devices")[0], 200)
        self.assertEqual(self.request("GET", "/direction")[1]["direction"], "right")
        status, result = self.request("POST", "/direction/test-haptic", {})
        self.assertEqual(status, 200)
        self.assertTrue(result["haptic"]["queued"])
        path = "/device/command?" + urlencode(self.messages["right"])
        self.assertIsNotNone(self.request("GET", path)[1]["command"])
        self.assertIsNone(self.request("GET", path)[1]["command"])
        self.assertEqual(self.request("POST", "/device/register", {"device_id": str(uuid.uuid4()), "role": "right"})[0], 409)
        self.assertEqual(self.request("POST", "/device/rms", {**self.messages["front"], "rms_dbfs": float("nan")})[0], 400)
        self.assertEqual(self.request("GET", "/device/command?device_id=invalid&role=front")[0], 400)
        self.assertEqual(self.request("POST", "/device/register", [1])[0], 400)
        self.adapter.infer.assert_not_called()

    def test_inference_does_not_block_reports_poll_or_health_and_uses_start_snapshot(self):
        # A deterministic server clock isolates timing selection from test-machine load.
        now = [100.0]
        self.server.coordinator.clock = lambda: now[0]
        self.populate()
        entered, release = threading.Event(), threading.Event()
        def infer(_):
            entered.set()
            if not release.wait(5):
                raise TimeoutError("test did not release model")
            return {"label": "siren", "confidence": 0.8, "inference_ms": 1}
        self.adapter.infer.side_effect = infer
        with ThreadPoolExecutor(1) as pool:
            future = pool.submit(self.request, "POST", "/infer", bytes(80000), True)
            try:
                self.assertTrue(entered.wait(2))
                now[0] += 1  # Original RMS becomes stale while inference is blocked.
                for role in ROLES:
                    rms = -10 if role == "left" else -40
                    self.assertEqual(self.request("POST", "/device/rms", {**self.messages[role], "rms_dbfs": rms})[0], 200)
                self.assertEqual(self.request("GET", "/health")[1], {"status": "ok"})
                self.assertEqual(self.request("GET", "/direction")[1]["direction"], "left")
                path = "/device/command?" + urlencode(self.messages["front"])
                self.assertEqual(self.request("GET", path)[0], 200)
            finally:
                release.set()
            status, result = future.result()
        self.assertEqual(status, 200)
        self.assertEqual(result["direction"], "right")
        self.assertTrue(result["haptic"]["queued"])
        path = "/device/command?" + urlencode(self.messages["right"])
        self.assertEqual(self.request("GET", path)[1]["command"]["role"], "right")


if __name__ == "__main__":
    unittest.main()
