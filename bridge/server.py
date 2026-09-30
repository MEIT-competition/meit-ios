"""Concurrent LAN HTTP bridge with serialized AI inference. No audio is saved."""
import argparse
import json
import logging
import os
import socket
import sys
import time
import threading
from urllib.parse import parse_qs, urlsplit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from automatic import AutomaticDetection, increment
from wearable import WearableEvents, direction_metadata, result_metadata
from meit_ai_adapter import MEITAIAdapter, PAYLOAD_BYTES
from coordination import Coordinator, ProtocolError, RMS_MAX_AGE_SECONDS, DIRECTION_MARGIN_DB

METADATA = {"X-Audio-Sample-Rate": "16000", "X-Audio-Channels": "1",
            "X-Audio-Format": "pcm16le", "X-Audio-Samples": "40000"}


class BridgeServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, adapter, coordinator=None, automatic=None):
        self.adapter = adapter
        self.coordinator = coordinator if coordinator is not None else Coordinator()
        self.automatic = automatic if automatic is not None else AutomaticDetection(self.coordinator)
        self.wearable = WearableEvents(self.automatic, self.coordinator.rms_max_age)
        self.inference_lock = threading.Lock()
        self.stats_lock = threading.Lock()
        self.counters = {"rms_reports_count": 0, "inference_count": 0}
        super().__init__(address, BridgeHandler)

    def count(self, key):
        with self.stats_lock:
            increment(self.counters, key)

    def diagnostics(self):
        with self.stats_lock:
            counts = dict(self.counters)
        return {"auto": self.automatic.diagnostics(), "wearable": self.wearable.status(),
                **self.coordinator.diagnostics_counts(),
                **counts, "model_loaded": True, "inference_busy": self.inference_lock.locked()}

    def service_actions(self):
        # serve_forever ticks even when no phone sends another request.
        self.automatic.tick()

    def handle_error(self, request, client_address):
        print("Bridge request failed; connection closed.", file=sys.stderr)


class BridgeHandler(BaseHTTPRequestHandler):
    server_version = "MEITBridge/1"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, format, *args):
        # Do not log request headers, client addresses, PCM, or arbitrary request paths.
        pass

    def reply(self, status, value):
        body = json.dumps(value, allow_nan=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            pass

    def fail(self, status, code, message):
        self.reply(status, {"error": {"code": code, "message": message}})
        # An immediate close with unread upload data can reset the TCP connection on
        # Windows and hide the JSON error. Half-close the response, then drain only
        # a bounded amount/time; malformed input is never passed to inference.
        try:
            self.wfile.flush()
            self.connection.shutdown(socket.SHUT_WR)
            deadline = time.monotonic() + 0.25
            remaining = PAYLOAD_BYTES + 1
            while remaining:
                timeout = deadline - time.monotonic()
                if timeout <= 0:
                    break
                self.connection.settimeout(timeout)
                chunk = self.rfile.read1(min(8192, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
        except OSError:
            pass

    def do_GET(self):
        coordinator = self.server.coordinator
        try:
            path = urlsplit(self.path)
            if path.path == "/health" and not path.query:
                result = {"status": "ok"}
            elif path.path == "/diagnostics" and not path.query:
                result = self.server.diagnostics()
            elif path.path == "/auto/status" and not path.query:
                result = self.server.automatic.status()
            elif path.path == "/wearable/status" and not path.query:
                result = self.server.wearable.status()
            elif path.path == "/devices" and not path.query:
                result = coordinator.list_devices()
            elif path.path == "/direction" and not path.query:
                result = coordinator.selection().result
            elif path.path == "/device/command":
                query = parse_qs(path.query, keep_blank_values=True, max_num_fields=4)
                if set(query) != {"device_id", "role"} or any(len(v) != 1 for v in query.values()):
                    raise ProtocolError(400, "invalid_query", "Expected one device_id and role.")
                self.server.automatic.tick()
                result = coordinator.poll({key: value[0] for key, value in query.items()})
                result["auto"] = self.server.automatic.status()
            else:
                raise ProtocolError(404, "not_found", "Unknown bridge endpoint.")
            self.reply(200, result)
        except ProtocolError as error:
            self.fail(error.status, error.code, error.message)
        except ValueError:
            self.fail(400, "invalid_query", "Invalid endpoint or query.")

    def json_body(self):
        if self.headers.get_all("Transfer-Encoding") or self.headers.get_all("Content-Encoding"):
            raise ProtocolError(400, "invalid_encoding", "Send uncompressed JSON with Content-Length.")
        if self.headers.get_all("Content-Type") != ["application/json"]:
            raise ProtocolError(400, "invalid_content_type", "Expected application/json.")
        lengths = self.headers.get_all("Content-Length") or []
        if len(lengths) != 1 or len(lengths[0]) > 4 or not lengths[0].isascii() or not lengths[0].isdigit() or not 0 < int(lengths[0]) <= 4096:
            raise ProtocolError(400, "invalid_length", "JSON body must be 1 to 4096 bytes.")
        try:
            body = self.rfile.read(int(lengths[0]))
            if len(body) != int(lengths[0]):
                raise ValueError()
            value = json.loads(body)
            if not isinstance(value, dict):
                raise ValueError()
            return value
        except socket.timeout:
            raise ProtocolError(408, "body_timeout", "JSON body read timed out.") from None
        except (ValueError, UnicodeError):
            raise ProtocolError(400, "invalid_json", "Expected a complete JSON object.") from None

    def do_POST(self):
        coordinator = self.server.coordinator
        if self.path in ("/device/register", "/device/rms", "/direction/test-haptic", "/auto/start", "/auto/stop"):
            try:
                body = self.json_body()
                if self.path == "/device/register":
                    result = coordinator.register(body)
                elif self.path == "/device/rms":
                    result = coordinator.report_rms(body)
                    self.server.count("rms_reports_count")
                    self.server.automatic.observe()
                elif self.path in ("/auto/start", "/auto/stop"):
                    result = self.server.automatic.set_enabled(self.path == "/auto/start")
                else:
                    result = coordinator.test_haptic()
                self.reply(200, result)
            except ProtocolError as error:
                self.fail(error.status, error.code, error.message)
            return
        if self.path == "/wearable/observe":
            try:
                self.reply(200, self.server.wearable.observe(self.json_body()))
            except ProtocolError as error:
                self.fail(error.status, error.code, error.message)
            return
        if self.path not in ("/infer", "/event/audio", "/wearable/infer"):
            self.fail(404, "not_found", "Unknown bridge endpoint.")
            return
        if self.headers.get_all("Transfer-Encoding"):
            self.fail(400, "transfer_encoding", "Chunked input is not supported.")
            return
        if self.headers.get_all("Content-Encoding"):
            self.fail(415, "content_encoding", "Send uncompressed PCM16LE.")
            return
        expected = {"Content-Type": "application/octet-stream", **METADATA}
        for name, value in expected.items():
            if self.headers.get_all(name) != [value]:
                self.fail(400, "invalid_metadata", f"Expected one {name}: {value} header.")
                return
        lengths = self.headers.get_all("Content-Length")
        if not lengths:
            self.fail(411, "length_required", "Content-Length is required.")
            return
        if lengths != [str(PAYLOAD_BYTES)]:
            self.fail(400, "invalid_length", "Expected exactly 80000 bytes / 40000 samples.")
            return
        wearable = self.path == "/wearable/infer"
        direction = None
        wearable_ids = {}
        if wearable:
            try:
                direction = direction_metadata(self.headers.get_all("X-Wearable-Direction"))
                for name in ("X-Wearable-Session", "X-Wearable-Event"):
                    values = self.headers.get_all(name)
                    if values is not None and len(values) != 1:
                        raise ProtocolError(400, "invalid_wearable_metadata", "Duplicate Wearable ID header.")
                    wearable_ids[name] = values[0] if values else None
            except ProtocolError as error:
                self.fail(error.status, error.code, error.message)
                return
        automatic = self.path == "/event/audio"
        metadata = {}
        if automatic:
            for header, key in (("X-Event-ID", "event_id"), ("X-Device-ID", "device_id"), ("X-Device-Role", "role")):
                values = self.headers.get_all(header)
                if values is None or len(values) != 1:
                    self.fail(400, "invalid_event_metadata", f"Expected one {header} header.")
                    return
                metadata[key] = values[0]
        try:
            payload = self.rfile.read(PAYLOAD_BYTES)
        except socket.timeout:
            self.fail(408, "body_timeout", "PCM input read timed out (10 seconds idle).")
            return
        if len(payload) != PAYLOAD_BYTES:
            self.fail(400, "incomplete_body", "PCM body is shorter than Content-Length.")
            return
        claimed = None
        wearable_claim = None
        try:
            if automatic:
                claimed = self.server.automatic.claim_audio(metadata)
            if wearable:
                wearable_claim = self.server.wearable.claim(wearable_ids["X-Wearable-Session"], wearable_ids["X-Wearable-Event"])
            with self.server.inference_lock:
                if wearable:
                    # Reuse decoding/predict_array and existing confidence/dB decision only.
                    # Never select a coordination direction, complete an auto event, or queue haptics.
                    self.server.count("inference_count")
                    result = result_metadata(self.server.adapter.infer_auto(payload), direction)
                    # Publish the completed inference so the EE belt bridge can poll
                    # /wearable/status. Publication only: no direction selection,
                    # auto-event completion, or haptic queueing on this path.
                    self.server.wearable.record(result, direction, wearable_ids["X-Wearable-Event"])
                    logging.getLogger("meit.wearable").info("[WEARABLE] POST /wearable/infer completed")
                elif automatic:
                    self.server.automatic.check_inference(claimed)
                    self.server.count("inference_count")
                    result = self.server.adapter.infer_auto(payload)
                    result = self.server.automatic.complete(claimed, result)
                else:
                    # Manual Phase 4 still selects direction immediately before inference.
                    selected = coordinator.selection()
                    self.server.count("inference_count")
                    result = self.server.adapter.infer(payload)
                    result = coordinator.after_inference(result, selected)
        except ProtocolError as error:
            if claimed is not None:
                self.finish_failed_auto(claimed)
            # Release the Wearable slot BEFORE the error response, matching the
            # success path, so a phone that retries after reading the error never
            # races the slot release and gets a spurious 409. finish() is
            # idempotent, so the finally below is a harmless no-op afterwards.
            if wearable_claim is not None:
                self.server.wearable.finish(wearable_claim)
            self.fail(error.status, error.code, error.message)
            return
        except Exception as error:
            if claimed is not None:
                self.finish_failed_auto(claimed)
            if wearable_claim is not None:
                self.server.wearable.finish(wearable_claim)
            # Keep private paths and model internals out of the HTTP response and logs.
            print(f"Inference failed ({type(error).__name__}).", file=sys.stderr)
            self.fail(500, "inference_failed", "Existing meit-ai inference failed; check bridge terminal.")
            return
        finally:
            if wearable_claim is not None:
                self.server.wearable.finish(wearable_claim)
        self.reply(200, result)

    def finish_failed_auto(self, event_id):
        try:
            self.server.automatic.complete(event_id)
        except ProtocolError:
            pass  # Already completed/stopped; never alter a newer event.


def main():
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ai-path", default=os.environ.get("MEIT_AI_PATH"))
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--rms-max-age-ms", type=float, default=RMS_MAX_AGE_SECONDS * 1000)
    parser.add_argument("--direction-margin-db", type=float, default=DIRECTION_MARGIN_DB)
    parser.add_argument("--auto-trigger-dbfs", type=float, default=-30.0)
    parser.add_argument("--auto-cooldown-ms", type=float, default=3000)
    parser.add_argument("--auto-audio-timeout-ms", type=float, default=3000)
    parser.add_argument("--auto-rearm-quiet-ms", type=float, default=750)
    args = parser.parse_args()
    if not args.ai_path:
        parser.error("Set MEIT_AI_PATH or --ai-path to the existing meit-ai repository.")
    try:
        coordinator = Coordinator(rms_max_age=args.rms_max_age_ms / 1000, margin_db=args.direction_margin_db)
        automatic = AutomaticDetection(coordinator, trigger_dbfs=args.auto_trigger_dbfs,
                                       cooldown=args.auto_cooldown_ms / 1000,
                                       audio_timeout=args.auto_audio_timeout_ms / 1000,
                                       rearm_quiet=args.auto_rearm_quiet_ms / 1000)
    except ValueError as error:
        parser.error(str(error))
    try:
        adapter = MEITAIAdapter(args.ai_path)
        server = BridgeServer((args.host, args.port), adapter, coordinator, automatic)
    except Exception as error:
        print(f"Bridge startup failed ({type(error).__name__}). Check AI path, dependencies, "
              "SavedModel/calibration, and whether the port is already in use.", file=sys.stderr)
        return 1
    print("MEIT bridge ready\nAI repository: meit-ai (external)\nModel loaded")
    print(f"Listening: {args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
