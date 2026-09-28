"""Single-request-at-a-time LAN bridge. No audio is written to disk."""
import argparse
import json
import os
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

from meit_ai_adapter import MEITAIAdapter, PAYLOAD_BYTES

METADATA = {"X-Audio-Sample-Rate": "16000", "X-Audio-Channels": "1",
            "X-Audio-Format": "pcm16le", "X-Audio-Samples": "40000"}


class BridgeServer(HTTPServer):
    # HTTPServer deliberately serializes inference; the existing model need not be thread-safe.
    def __init__(self, address, adapter):
        self.adapter = adapter
        super().__init__(address, BridgeHandler)

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
        if self.path != "/health":
            self.fail(404, "not_found", "Use GET /health or POST /infer.")
            return
        self.reply(200, {"status": "ok"})

    def do_POST(self):
        if self.path != "/infer":
            self.fail(404, "not_found", "Use GET /health or POST /infer.")
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
        try:
            payload = self.rfile.read(PAYLOAD_BYTES)
        except socket.timeout:
            self.fail(408, "body_timeout", "PCM input read timed out (10 seconds idle).")
            return
        if len(payload) != PAYLOAD_BYTES:
            self.fail(400, "incomplete_body", "PCM body is shorter than Content-Length.")
            return
        try:
            result = self.server.adapter.infer(payload)
        except Exception as error:
            # Keep private paths and model internals out of the HTTP response and logs.
            print(f"Inference failed ({type(error).__name__}).", file=sys.stderr)
            self.fail(500, "inference_failed", "Existing meit-ai inference failed; check bridge terminal.")
            return
        self.reply(200, result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ai-path", default=os.environ.get("MEIT_AI_PATH"))
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if not args.ai_path:
        parser.error("Set MEIT_AI_PATH or --ai-path to the existing meit-ai repository.")
    try:
        adapter = MEITAIAdapter(args.ai_path)
        server = BridgeServer((args.host, args.port), adapter)
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
