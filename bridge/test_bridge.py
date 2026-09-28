"""Protocol tests use an explicit test double, never claim real-model accuracy."""
import http.client
import json
import socket
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import numpy as np

from meit_ai_adapter import MEITAIAdapter, PAYLOAD_BYTES
from server import BridgeServer, METADATA


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.adapter = Mock()
        self.adapter.infer.return_value = {"label": "normal", "confidence": 0.75, "inference_ms": 1.2}
        self.server = BridgeServer(("127.0.0.1", 0), self.adapter)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.headers = {"Content-Type": "application/octet-stream", **METADATA}

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        try:
            connection.request(method, path, body, headers or {})
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def test_health_does_not_infer(self):
        self.assertEqual(self.request("GET", "/health"), (200, {"status": "ok"}))
        self.adapter.infer.assert_not_called()

    def test_valid_snapshot(self):
        body = bytes(PAYLOAD_BYTES)
        status, response = self.request("POST", "/infer", body, self.headers)
        self.assertEqual(status, 200)
        self.assertEqual(response, self.adapter.infer.return_value)
        self.adapter.infer.assert_called_once_with(body)

    def test_invalid_metadata_never_reaches_ai(self):
        for name in self.headers:
            for value in [None, "incorrect"]:
                with self.subTest(name=name, value=value):
                    headers = self.headers.copy()
                    if value is None:
                        del headers[name]
                    else:
                        headers[name] = value
                    status, response = self.request("POST", "/infer", bytes(PAYLOAD_BYTES), headers)
                    self.assertEqual(status, 400)
                    self.assertEqual(response["error"]["code"], "invalid_metadata")
        self.adapter.infer.assert_not_called()

    def test_wrong_body_lengths(self):
        for size in [0, 79_999, 80_001, 80_044]:
            with self.subTest(size=size):
                status, response = self.request("POST", "/infer", bytes(size), self.headers)
                self.assertEqual(status, 400)
                self.assertEqual(response["error"]["code"], "invalid_length")
        self.adapter.infer.assert_not_called()

    def test_compressed_or_chunked_body_rejected(self):
        for extra, expected in [( {"Content-Encoding": "gzip"}, 415),
                                ({"Transfer-Encoding": "chunked"}, 400)]:
            status, _ = self.request("POST", "/infer", bytes(PAYLOAD_BYTES), {**self.headers, **extra})
            self.assertEqual(status, expected)
        self.adapter.infer.assert_not_called()

    def test_unknown_endpoint(self):
        self.assertEqual(self.request("GET", "/unknown")[0], 404)
        self.assertEqual(self.request("POST", "/unknown")[0], 404)
        self.adapter.infer.assert_not_called()

    def raw_request(self, extra_headers, body=b""):
        with socket.create_connection(self.server.server_address, timeout=5) as connection:
            headers = "POST /infer HTTP/1.0\r\n" + "".join(
                f"{key}: {value}\r\n" for key, value in self.headers.items())
            connection.sendall((headers + extra_headers + "\r\n").encode() + body)
            connection.shutdown(socket.SHUT_WR)
            response = http.client.HTTPResponse(connection)
            response.begin()
            return response.status, json.loads(response.read())

    def test_missing_duplicate_length_and_short_read(self):
        self.assertEqual(self.raw_request("")[0], 411)
        self.assertEqual(self.raw_request("Content-Length: 80000\r\nContent-Length: 80000\r\n")[0], 400)
        status, response = self.raw_request("Content-Length: 80000\r\n", b"short")
        self.assertEqual(status, 400)
        self.assertEqual(response["error"]["code"], "incomplete_body")
        self.adapter.infer.assert_not_called()

    def test_duplicate_metadata_rejected(self):
        status, response = self.raw_request("Content-Length: 80000\r\nX-Audio-Channels: 1\r\n")
        self.assertEqual(status, 400)
        self.assertEqual(response["error"]["code"], "invalid_metadata")
        self.adapter.infer.assert_not_called()

    def test_body_timeout_does_not_infer(self):
        with socket.create_connection(self.server.server_address, timeout=15) as connection:
            headers = "POST /infer HTTP/1.0\r\n" + "".join(
                f"{key}: {value}\r\n" for key, value in self.headers.items())
            connection.sendall((headers + "Content-Length: 80000\r\n\r\n").encode())
            response = http.client.HTTPResponse(connection)
            response.begin()
            self.assertEqual(response.status, 408)
            self.assertEqual(json.loads(response.read())["error"]["code"], "body_timeout")
        self.adapter.infer.assert_not_called()

    def test_inference_error_is_sanitized_and_server_recovers(self):
        self.adapter.infer.side_effect = RuntimeError("private model path must not be exposed")
        status, response = self.request("POST", "/infer", bytes(PAYLOAD_BYTES), self.headers)
        self.assertEqual(status, 500)
        self.assertNotIn("private", json.dumps(response))
        self.assertEqual(self.request("GET", "/health")[0], 200)

    def test_inference_is_serialized(self):
        entered = threading.Event()
        release = threading.Event()
        count = 0
        def infer(_):
            nonlocal count
            count += 1
            if count == 1:
                entered.set()
                self.assertTrue(release.wait(5))
            return {"label": "normal", "confidence": 0.75, "inference_ms": 1.2}
        self.adapter.infer.side_effect = infer
        with ThreadPoolExecutor(2) as pool:
            first = pool.submit(self.request, "POST", "/infer", bytes(PAYLOAD_BYTES), self.headers)
            self.assertTrue(entered.wait(5))
            second = pool.submit(self.request, "POST", "/infer", bytes(PAYLOAD_BYTES), self.headers)
            try:
                with self.assertRaises(FutureTimeout):
                    second.result(timeout=0.2)
                self.assertEqual(count, 1)
            finally:
                release.set()
            self.assertEqual(first.result()[0], 200)
            self.assertEqual(second.result()[0], 200)
        self.assertEqual(count, 2)


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.adapter = MEITAIAdapter.__new__(MEITAIAdapter)
        self.adapter.np = np
        self.api = SimpleNamespace(CLASSES=["horn", "siren", "crash", "normal"], SR=16000, CLIP_SEC=2.5,
                                   load_model=Mock(), load_temperature=Mock(), predict_array=Mock())
        self.api.predict_array.return_value = ({"horn": 0.1, "siren": 0.7, "crash": 0.1, "normal": 0.1}, -20)
        self.adapter.api = self.api

    def test_decodes_signed_little_endian_without_new_preprocessing(self):
        raw = b"\x00\x80\xff\xff\x00\x00\xff\x7f" + bytes(PAYLOAD_BYTES - 8)
        result = self.adapter.infer(raw)
        waveform = self.api.predict_array.call_args.args[0]
        self.assertEqual(waveform.dtype, np.float32)
        self.assertEqual(waveform.shape, (40000,))
        np.testing.assert_array_equal(waveform[:4], np.array([-1, -1/32768, 0, 32767/32768], dtype=np.float32))
        self.assertEqual(result["label"], "siren")
        self.assertEqual(result["confidence"], 0.7)
        self.assertGreaterEqual(result["inference_ms"], 0)

    def test_invalid_payload_or_model_output(self):
        with self.assertRaises(ValueError):
            self.adapter.infer(b"short")
        self.api.predict_array.assert_not_called()
        for value in [float("nan"), float("inf"), -1, 2]:
            self.api.predict_array.return_value = ({c: value for c in self.api.CLASSES}, -20)
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.adapter.infer(bytes(PAYLOAD_BYTES))

    def test_startup_loads_existing_api_once(self):
        import sys
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = root / "classifier" / "adapter.py"
            entry.parent.mkdir()
            entry.touch()
            model = root / "model" / "saved_model" / "danger_sound_classifier"
            model.mkdir(parents=True)
            (model / "saved_model.pb").touch()
            def modules(name):
                return self.api if name == "classifier.adapter" else np
            with patch("meit_ai_adapter.importlib.util.find_spec", return_value=SimpleNamespace(origin=str(entry))), \
                 patch("meit_ai_adapter.importlib.import_module", side_effect=modules), \
                 patch.object(sys, "path", sys.path.copy()):
                adapter = MEITAIAdapter(root)
                adapter.infer(bytes(PAYLOAD_BYTES))
                adapter.infer(bytes(PAYLOAD_BYTES))
            self.api.load_model.assert_called_once()
            self.api.load_temperature.assert_called_once()
            self.assertEqual(self.api.predict_array.call_count, 2)


if __name__ == "__main__":
    unittest.main()
