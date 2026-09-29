"""Phase 6A timing, recovery, privacy and accelerated HTTP soak regressions."""
import gc
import http.client
import json
import threading
import time
import tracemalloc
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import Mock
from urllib.parse import urlencode

from automatic import AutomaticDetection, COUNTER_MAX
from coordination import Coordinator, ProtocolError
from server import BridgeServer, METADATA


class TimingTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.c = Coordinator(clock=lambda: self.now)
        self.auto = AutomaticDetection(self.c)
        self.device = {"device_id": str(uuid.uuid4()), "role": "front"}
        self.c.register(self.device)

    def report(self, level):
        self.c.report_rms({**self.device, "rms_dbfs": level, "ai_buffer_ready": True})
        self.auto.observe()

    def test_timing_logs_and_redacted_history_use_one_monotonic_clock(self):
        self.auto.set_enabled(True)
        enqueue = self.c.enqueue_snapshot
        def delayed(*args):
            self.now += .01
            return enqueue(*args)
        self.c.enqueue_snapshot = delayed
        with self.assertLogs("meit.auto", level="INFO") as logs:
            self.report(-20)
            event = self.auto.active["event_id"]
            self.now += .2
            self.auto.claim_audio({**self.device, "event_id": event})
            self.now += .05  # model lock wait
            self.auto.check_inference(event)
            self.now += .1
            self.auto.complete(event, {"label": "siren", "confidence": .9, "inference_ms": 80, "danger": True})
        record = self.auto.last_event
        expected = {"trigger_to_command_ms": 10, "command_to_audio_ms": 200,
                    "audio_to_inference_start_ms": 50, "inference_ms": 100, "total_event_ms": 360}
        for key, value in expected.items():
            self.assertAlmostEqual(record["latency"][key], value)
        self.assertEqual(record["result"]["inference_ms"], 80)  # Existing predict_array metric unchanged.
        self.assertAlmostEqual(record["timestamps_ms"]["triggered"], 0)
        self.assertEqual(record["trigger_rms_dbfs"], -20)
        self.assertEqual(record["trigger_threshold_dbfs"], -30)
        exported = json.dumps(self.auto.diagnostics())
        self.assertNotIn(event, exported)
        self.assertNotIn(self.device["device_id"], exported)
        self.assertNotRegex(exported, r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
        self.assertNotIn(event, "\n".join(logs.output))
        self.assertNotIn(self.device["device_id"], "\n".join(logs.output))
        self.assertEqual(len(logs.output), 6)

    def test_timeout_then_quiet_then_next_event_and_old_upload_never_claims_new_event(self):
        self.auto.set_enabled(True)
        self.report(-20)
        old = self.auto.active["event_id"]
        self.now += 3.1
        state = self.auto.status()
        self.assertEqual(state["last_event"]["outcome"], "audio_timeout")
        self.assertIsNone(state["last_event"]["latency"]["inference_ms"])
        self.assertAlmostEqual(state["cooldown_remaining_ms"], 3000)
        for _ in range(35):
            self.now += .1
            self.report(-20)
        self.assertIsNone(self.auto.active)
        self.assertTrue(self.auto.status()["waiting_for_quiet"])
        for _ in range(5):
            self.now += .1
            self.report(-40)
        self.assertAlmostEqual(self.auto.status()["quiet_elapsed_ms"], 400)
        self.now += .6  # No reports: status must not pretend this was observed quiet.
        self.assertEqual(self.auto.status()["quiet_elapsed_ms"], 0)
        self.assertFalse(self.auto.armed)
        for _ in range(10):
            self.now += .1
            self.report(-40)
        self.assertTrue(self.auto.armed)
        self.report(-20)
        new = self.auto.active["event_id"]
        self.assertNotEqual(old, new)
        with self.assertRaises(ProtocolError):
            self.auto.claim_audio({**self.device, "event_id": old})
        self.assertEqual(self.auto.active["event_id"], new)
        self.assertEqual(self.auto.claim_audio({**self.device, "event_id": new}), new)
        self.assertEqual(self.auto.counters["timeout_count"], 1)
        self.assertEqual(self.auto.counters["inactive_rejects"], 1)


class ReliabilityHTTPTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.adapter = Mock()
        self.adapter.infer.return_value = {"label": "normal", "confidence": .8, "inference_ms": 1}
        self.adapter.infer_auto.return_value = {**self.adapter.infer.return_value, "danger": False}
        self.device = {"device_id": str(uuid.uuid4()), "role": "front"}
        self.pcm = bytes(80000)
        self.start_server()

    def start_server(self):
        self.server = BridgeServer(("127.0.0.1", 0), self.adapter, Coordinator(clock=lambda: self.now))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def tearDown(self):
        self.stop_server()

    def request(self, method, path, data=None, headers=None):
        pcm = isinstance(data, bytes)
        body = data if pcm else json.dumps(data).encode() if data is not None else None
        headers = ({"Content-Type": "application/octet-stream", **METADATA, **(headers or {})} if pcm
                   else {"Content-Type": "application/json"})
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        try:
            connection.request(method, path, body, headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def register(self):
        self.assertEqual(self.request("POST", "/device/register", self.device)[0], 200)

    def report(self, level):
        self.assertEqual(self.request("POST", "/device/rms", {**self.device, "rms_dbfs": level,
                                                             "ai_buffer_ready": True})[0], 200)

    def poll(self):
        return self.request("GET", "/device/command?" + urlencode(self.device))

    def trigger(self):
        self.request("POST", "/auto/start", {})
        self.report(-20)
        command = self.poll()[1]["command"]
        self.assertEqual(command["kind"], "infer_snapshot")
        return {"X-Event-ID": command["event_id"], "X-Device-ID": self.device["device_id"], "X-Device-Role": "front"}

    def test_restart_requires_registration_and_syncs_default_off_without_restoring_event(self):
        self.register()
        old = self.trigger()
        self.stop_server()
        self.start_server()  # Same client identity; a genuinely new server/registry/state.
        self.assertEqual(self.poll()[0], 404)
        self.register()
        response = self.poll()[1]
        self.assertFalse(response["auto"]["enabled"])
        self.assertEqual(response["auto"]["state"], "IDLE")
        self.assertIsNone(response["command"])
        self.assertEqual(self.request("POST", "/event/audio", self.pcm, old)[0], 409)
        self.adapter.infer_auto.assert_not_called()
        self.assertEqual(self.request("POST", "/event/audio", self.pcm, self.trigger())[0], 200)

    def test_manual_fallback_in_all_auto_modes_and_diagnostics_during_inference(self):
        self.register()
        self.assertEqual(self.request("POST", "/infer", self.pcm)[0], 200)  # OFF
        headers = self.trigger()
        self.assertEqual(self.request("POST", "/infer", self.pcm)[0], 200)  # ON / waiting
        entered, release = threading.Event(), threading.Event()
        def infer(_):
            entered.set()
            if not release.wait(4):
                raise TimeoutError()
            return self.adapter.infer_auto.return_value
        self.adapter.infer_auto.side_effect = infer
        with ThreadPoolExecutor(1) as pool:
            future = pool.submit(self.request, "POST", "/event/audio", self.pcm, headers)
            try:
                self.assertTrue(entered.wait(2))
                diag = self.request("GET", "/diagnostics")[1]
                self.assertTrue(diag["inference_busy"])
                self.assertEqual(diag["auto"]["state"], "INFERENCING")
                self.report(-20)
                self.assertEqual(self.request("GET", "/health")[0], 200)
                self.assertEqual(self.poll()[0], 200)
            finally:
                release.set()
            self.assertEqual(future.result()[0], 200)
        self.assertEqual(self.request("POST", "/infer", self.pcm)[0], 200)  # COOLDOWN
        self.now += 3.1
        self.report(-20)
        self.assertTrue(self.request("GET", "/auto/status")[1]["waiting_for_quiet"])
        self.assertEqual(self.request("POST", "/infer", self.pcm)[0], 200)  # Quiet rearm wait
        diag = self.request("GET", "/diagnostics")[1]
        self.assertEqual(diag["inference_count"], 5)
        self.assertFalse(diag["inference_busy"])
        self.assertNotIn(self.device["device_id"], json.dumps(diag))
        self.assertNotIn(headers["X-Event-ID"], json.dumps(diag))
        self.assertLess(len(json.dumps(self.poll()[1])), 16384)  # Existing iPhone JSON limit.

    def test_diagnostic_counters_saturate_and_repeated_controls_are_idempotent(self):
        self.register()
        self.server.counters["rms_reports_count"] = COUNTER_MAX - 1
        for _ in range(4):
            self.report(-50)
        self.assertEqual(self.request("GET", "/diagnostics")[1]["rms_reports_count"], COUNTER_MAX)
        self.server.automatic.counters["stopped_count"] = COUNTER_MAX
        self.trigger()
        for _ in range(5):
            self.request("POST", "/auto/stop", {})
        self.assertEqual(len(self.server.automatic.recent_events), 1)
        self.assertEqual(self.server.automatic.counters["stopped_count"], COUNTER_MAX)
        self.assertIsNone(self.poll()[1]["command"])
        for _ in range(5):
            self.request("POST", "/auto/start", {})
        self.assertIsNone(self.server.automatic.active)
        self.adapter.infer_auto.assert_not_called()

    def test_accelerated_http_soak_bounded_history_threads_and_memory(self):
        self.register()
        # Mock records every PCM argument; a stateless fake avoids measuring test-owned audio retention.
        output = self.adapter.infer_auto.return_value
        model_calls = 0
        def infer(_):
            nonlocal model_calls
            model_calls += 1
            return output
        self.adapter.infer_auto = infer
        baseline_threads = threading.active_count()
        peak_threads = baseline_threads
        tracemalloc.start()
        warm_memory = None
        try:
            for cycle in range(60):
                headers = self.trigger()
                self.assertEqual(self.request("POST", "/event/audio", self.pcm, headers)[0], 200)
                self.assertEqual(self.request("POST", "/event/audio", self.pcm, headers)[0], 409)
                # Sustained sound outlasts cooldown. No second event without observed quiet.
                for _ in range(35):
                    self.now += .1
                    self.report(-20)
                    self.assertIsNone(self.poll()[1]["command"])
                for _ in range(10):
                    self.now += .1
                    self.report(-40)
                    self.assertIsNone(self.poll()[1]["command"])
                self.assertEqual(self.request("GET", "/health")[0], 200)
                self.request("POST", "/auto/stop", {})
                diag = self.request("GET", "/diagnostics")[1]
                self.assertEqual(diag["auto"]["recent_event_count"], min(cycle + 1, 20))
                self.assertLessEqual(diag["pending_command_count"], 1)
                self.assertEqual(diag["registered_device_count"], 1)
                self.assertIsNone(diag["auto"]["active_event"])
                peak_threads = max(peak_threads, threading.active_count())
                if cycle == 19:
                    gc.collect()
                    warm_memory = tracemalloc.get_traced_memory()[0]
            # Allow request handlers to finish after their response bytes were received.
            deadline = time.monotonic() + 2
            while threading.active_count() > baseline_threads and time.monotonic() < deadline:
                time.sleep(.01)
            gc.collect()
            growth = tracemalloc.get_traced_memory()[0] - warm_memory
            self.assertLess(growth, 1024 * 1024)  # Bounded retention, not an RSS/allocator claim.
            self.assertLessEqual(threading.active_count(), baseline_threads)
            self.assertLessEqual(peak_threads, baseline_threads + 8)
            self.assertEqual(diag["rms_reports_count"], 2760)
            self.assertEqual(diag["inference_count"], 60)
            self.assertEqual(diag["auto"]["counters"]["duplicate_rejects"], 60)
            self.assertEqual(diag["auto"]["counters"]["trigger_count"], 60)
            self.assertEqual(model_calls, 60)
            print(f"SOAK: RMS=2760 events=60 duplicate rejects=60 history=20 registry=1 "
                  f"threads baseline/peak/final={baseline_threads}/{peak_threads}/{threading.active_count()} "
                  f"retained growth after warmup={growth} bytes")
        finally:
            tracemalloc.stop()


if __name__ == "__main__":
    unittest.main()
