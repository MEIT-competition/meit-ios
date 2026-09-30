"""Wearable HTTP/gate regression tests. Classifier is a test double, no real audio/model."""
import http.client
import json
import socket
import threading
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import Mock, patch

from automatic import AutomaticDetection
from coordination import Coordinator, ProtocolError
from server import BridgeServer, METADATA
from wearable import WearableEvents


class WearableHTTPTests(unittest.TestCase):
    def setUp(self):
        self.adapter = Mock()
        self.prediction = {"label": "horn", "confidence": .96, "inference_ms": 2.5, "danger": True}
        self.adapter.infer_auto.return_value = self.prediction
        self.adapter.infer.return_value = {k: v for k, v in self.prediction.items() if k != "danger"}
        self.server = BridgeServer(("127.0.0.1", 0), self.adapter)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.headers = {"Content-Type": "application/octet-stream", **METADATA}
        self.session_id = str(uuid.uuid4())

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, path="/wearable/infer", body=None, headers=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        try:
            connection.request("POST", path, bytes(80000) if body is None else body,
                               self.headers if headers is None else headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def observe(self, level=-20, ready=True):
        return self.request("/wearable/observe", json.dumps({"session_id": self.session_id,
                            "rms_dbfs": level, "buffer_ready": ready}).encode(),
                            {"Content-Type": "application/json"})

    def test_valid_pcm_and_direction_echo_without_any_coordination_calls(self):
        with patch.object(self.server.coordinator, "selection") as selection, \
             patch.object(self.server.coordinator, "after_inference") as after, \
             patch.object(self.server.coordinator, "enqueue") as enqueue, \
             patch.object(self.server.coordinator, "register") as register, \
             patch.object(self.server.coordinator, "report_rms") as rms, \
             patch.object(self.server.automatic, "observe") as observe, \
             patch.object(self.server.automatic, "complete") as complete:
            status, event = self.observe()
            self.assertEqual(status, 200)
            status, result = self.request(headers={**self.headers, "X-Wearable-Direction": "left",
                "X-Wearable-Session": self.session_id, "X-Wearable-Event": event["event_id"]})
            self.assertEqual((status, result), (200, {**self.prediction, "direction": "left"}))
            self.adapter.infer_auto.assert_called_once_with(bytes(80000))
            self.adapter.infer.assert_not_called()
            for forbidden in (selection, after, enqueue, register, rms, observe, complete):
                forbidden.assert_not_called()
            self.assertEqual(self.server.coordinator.list_devices()["devices"], [])

    def test_unavailable_and_absent_direction_are_null(self):
        for direction in (None, "unavailable", "center", "right"):
            headers = dict(self.headers)
            if direction is not None:
                headers["X-Wearable-Direction"] = direction
            status, result = self.request(headers=headers)
            self.assertEqual(status, 200)
            self.assertEqual(result["direction"], direction if direction in ("center", "right") else None)

    def get(self, path):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        try:
            connection.request("GET", path)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def test_status_is_empty_until_an_inference_completes(self):
        self.assertEqual(self.get("/wearable/status"), (200, {"last_event": None}))

    def test_completed_inference_is_published_for_the_belt_bridge(self):
        # This is the EE belt-bridge contract: /wearable/status must carry the
        # same last_event shape the EE bridge already parses from /auto/status.
        _, event = self.observe()
        status, _ = self.request(headers={**self.headers, "X-Wearable-Direction": "left",
            "X-Wearable-Session": self.session_id, "X-Wearable-Event": event["event_id"]})
        self.assertEqual(status, 200)
        status, published = self.get("/wearable/status")
        self.assertEqual(status, 200)
        last = published["last_event"]
        self.assertEqual(last["event_id"], event["event_id"])
        self.assertEqual(last["outcome"], "completed")
        self.assertEqual(last["direction"], "left")
        self.assertEqual(last["result"]["label"], "horn")
        self.assertTrue(last["result"]["danger"])

    def test_unavailable_direction_is_published_as_unavailable(self):
        self.request(headers=self.headers)  # no X-Wearable-Direction -> unavailable
        self.assertEqual(self.get("/wearable/status")[1]["last_event"]["direction"], "unavailable")

    def test_status_polling_is_read_only_and_keeps_one_event_id(self):
        self.request(headers={**self.headers, "X-Wearable-Direction": "right"})
        first = self.get("/wearable/status")
        calls = self.adapter.infer_auto.call_count
        with patch.object(self.server.coordinator, "enqueue") as enqueue, \
             patch.object(self.server.automatic, "complete") as complete:
            self.assertEqual(self.get("/wearable/status"), first)
            self.assertEqual(self.get("/diagnostics")[1]["wearable"], first[1])
            enqueue.assert_not_called()
            complete.assert_not_called()
        self.assertEqual(self.adapter.infer_auto.call_count, calls)

    def test_status_preserves_non_alert_result_and_failed_inference_does_not_publish(self):
        self.adapter.infer_auto.return_value = {**self.prediction, "label": "normal", "danger": False}
        self.request(headers={**self.headers, "X-Wearable-Direction": "center"})
        retained = self.get("/wearable/status")[1]
        self.assertFalse(retained["last_event"]["result"]["danger"])
        self.adapter.infer_auto.side_effect = RuntimeError("test failure")
        self.assertEqual(self.request()[0], 500)
        self.assertIsNone(self.server.wearable.busy)
        self.assertEqual(self.get("/wearable/status")[1], retained)

    def test_wrong_pcm_sizes_and_metadata_do_not_classify(self):
        for size in (0, 79999, 80001):
            self.assertEqual(self.request(body=bytes(size))[1]["error"]["code"], "invalid_length")
        for name in self.headers:
            headers = {**self.headers, name: "wrong"}
            self.assertEqual(self.request(headers=headers)[1]["error"]["code"], "invalid_metadata")
        self.adapter.infer_auto.assert_not_called()

    def test_invalid_direction_and_id_pair_do_not_classify(self):
        for direction in ("LEFT", "front", "null", "", "left,right"):
            self.assertEqual(self.request(headers={**self.headers, "X-Wearable-Direction": direction})[1]["error"]["code"], "invalid_direction")
        self.assertEqual(self.request(headers={**self.headers, "X-Wearable-Session": self.session_id})[1]["error"]["code"], "invalid_wearable_metadata")
        self.adapter.infer_auto.assert_not_called()

    def test_duplicate_direction_header_rejected(self):
        with socket.create_connection(self.server.server_address, timeout=5) as sock:
            headers = "POST /wearable/infer HTTP/1.0\r\n" + "".join(f"{k}: {v}\r\n" for k,v in self.headers.items())
            sock.sendall((headers + "Content-Length: 80000\r\nX-Wearable-Direction: left\r\nX-Wearable-Direction: right\r\n\r\n").encode())
            sock.shutdown(socket.SHUT_WR)
            response = http.client.HTTPResponse(sock)
            response.begin()
            self.assertEqual(response.status, 400)
            self.assertEqual(json.loads(response.read())["error"]["code"], "invalid_direction")
        self.adapter.infer_auto.assert_not_called()

    def test_classifier_failure_releases_slot_and_sanitizes_response(self):
        self.adapter.infer_auto.side_effect = RuntimeError("secret model path")
        status, result = self.request()
        self.assertEqual(status, 500)
        self.assertEqual(result["error"]["code"], "inference_failed")
        self.assertNotIn("secret", json.dumps(result))
        self.assertIsNone(self.server.wearable.busy)
        self.adapter.infer_auto.side_effect = None
        self.assertEqual(self.request()[0], 200)

    def test_unsupported_label_and_invalid_result(self):
        for changes, code in (({"label": "other"}, "unsupported_label"),
                              ({"confidence": 1.01}, "invalid_response"),
                              ({"confidence": float("nan")}, "invalid_response"),
                              ({"inference_ms": -1}, "invalid_response"),
                              ({"danger": "true"}, "invalid_response")):
            self.adapter.infer_auto.return_value = {**self.prediction, **changes}
            status, result = self.request()
            self.assertEqual((status, result["error"]["code"]), (502, code))

    def test_existing_infer_still_selects_direction_and_after_inference(self):
        with patch.object(self.server.coordinator, "selection", return_value="selection") as selection, \
             patch.object(self.server.coordinator, "after_inference", return_value={"legacy": True}) as after:
            self.assertEqual(self.request("/infer"), (200, {"legacy": True}))
            selection.assert_called_once_with()
            after.assert_called_once_with(self.adapter.infer.return_value, "selection")
            self.adapter.infer.assert_called_once_with(bytes(80000))
            self.adapter.infer_auto.assert_not_called()

    def test_normal_and_low_confidence_decision_preserved(self):
        for label, confidence in (("normal", .99), ("siren", .3)):
            self.adapter.infer_auto.return_value = {**self.prediction, "label": label, "confidence": confidence, "danger": False}
            status, result = self.request()
            self.assertEqual(status, 200)
            self.assertFalse(result["danger"])
            self.assertEqual(result["label"], label)

    def test_one_inflight_even_with_concurrent_http_requests(self):
        entered, release = threading.Event(), threading.Event()
        def infer(_):
            entered.set()
            if not release.wait(5):
                raise RuntimeError("test release timeout")
            return self.prediction
        self.adapter.infer_auto.side_effect = infer
        with ThreadPoolExecutor(1) as pool:
            first = pool.submit(self.request)
            try:
                self.assertTrue(entered.wait(5))
                self.assertEqual(self.request()[1]["error"]["code"], "wearable_busy")
            finally:
                release.set()
            self.assertEqual(first.result(timeout=5)[0], 200)
        self.adapter.infer_auto.assert_called_once()

    def test_observation_event_consumed_once(self):
        status, event = self.observe()
        self.assertEqual(status, 200)
        self.assertIsNotNone(event["event_id"])
        self.assertIsNone(self.observe()[1]["event_id"])
        headers = {**self.headers, "X-Wearable-Session": self.session_id, "X-Wearable-Event": event["event_id"]}
        self.assertEqual(self.request(headers=headers)[0], 200)
        self.assertEqual(self.request(headers=headers)[1]["error"]["code"], "stale_event")
        self.assertIsNone(self.observe()[1]["event_id"])
        self.adapter.infer_auto.assert_called_once()

    def test_invalid_observation_rejected(self):
        for level, ready in ((True, True), (1, True), (-101, True), (float("nan"), True), (-20, "yes")):
            self.assertEqual(self.observe(level, ready)[0], 400)
        self.adapter.infer_auto.assert_not_called()


class WearableGateTests(unittest.TestCase):
    def setUp(self):
        self.now = 0.0
        self.coordinator = Coordinator(clock=lambda: self.now)
        self.auto = AutomaticDetection(self.coordinator)
        self.gate = WearableEvents(self.auto, self.coordinator.rms_max_age)
        self.session = str(uuid.uuid4())

    def observe(self, level=-20, ready=True):
        return self.gate.observe({"session_id": self.session, "rms_dbfs": level, "buffer_ready": ready})["event_id"]

    def finish(self):
        event = self.observe()
        self.assertIsNotNone(event)
        self.gate.finish(self.gate.claim(self.session, event))
        return event

    def test_defaults_and_configured_policy_are_reused(self):
        self.assertEqual((self.gate.trigger_dbfs, self.gate.cooldown, self.gate.rearm_quiet), (-30, 3, .75))
        auto = AutomaticDetection(self.coordinator, trigger_dbfs=-28, cooldown=4, rearm_quiet=1)
        other = WearableEvents(auto, self.coordinator.rms_max_age)
        self.assertEqual((other.trigger_dbfs, other.cooldown, other.rearm_quiet), (-28, 4, 1))

    def test_ready_and_trigger_boundary(self):
        self.assertIsNone(self.observe(-20, False))
        self.assertIsNone(self.observe(-30.01))
        self.assertIsNotNone(self.observe(-30))

    def test_sustained_sound_cannot_retrigger_after_cooldown(self):
        self.finish()
        for now in (1, 3, 30, 300):
            self.now = now
            self.assertIsNone(self.observe())

    def test_quiet_rearm_and_cooldown_both_required(self):
        self.finish()
        for now in (.25, .5, .75, 1):
            self.now = now
            self.assertIsNone(self.observe(-34))
        self.assertTrue(self.gate.armed)
        self.assertIsNone(self.observe())
        self.now = 3
        self.assertIsNotNone(self.observe())

    def test_quiet_boundary_and_missing_observations_reset_rearm(self):
        self.finish()
        for now in (1, 1.25, 1.5, 2):
            self.now = now
            self.observe(-33)
        self.assertFalse(self.gate.armed)
        self.now = 3
        self.observe(-34)
        self.now = 4  # A whole second without an observation is not proven quiet.
        self.observe(-34)
        self.assertFalse(self.gate.armed)
        for now in (4.25, 4.5, 4.75):
            self.now = now
            self.observe(-34)
        self.assertTrue(self.gate.armed)
        self.assertIsNotNone(self.observe())

    def test_expired_pending_event_cannot_classify_or_burst(self):
        event = self.observe()
        self.now = 3
        with self.assertRaises(ProtocolError):
            self.gate.claim(self.session, event)
        self.assertIsNone(self.observe())
        self.assertIsNone(self.gate.pending)
        self.now = 10
        self.assertIsNone(self.observe())

    def test_stale_session_and_concurrent_claim_rejected(self):
        event = self.observe()
        old = self.session
        self.session = str(uuid.uuid4())
        new_event = self.observe()
        with self.assertRaises(ProtocolError):
            self.gate.claim(old, event)
        token = self.gate.claim(self.session, new_event)
        with self.assertRaises(ProtocolError):
            self.gate.claim(self.session, new_event)
        self.session = str(uuid.uuid4())
        with self.assertRaises(ProtocolError):
            self.observe()
        self.gate.finish("stale token")
        self.assertEqual(self.gate.busy, token)
        self.gate.finish(token)
        self.assertIsNotNone(self.observe())


if __name__ == "__main__":
    unittest.main()
