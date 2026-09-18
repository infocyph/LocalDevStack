from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/version":
            self._json(200, {"version": "0.0.0-ci"})
            return

        if self.path == "/api/tags":
            self._json(
                200,
                {
                    "models": [
                        {
                            "name": "qwen2.5:3b",
                            "model": "qwen2.5:3b",
                            "size": 1,
                            "digest": "ci-fixture",
                        }
                    ]
                },
            )
            return

        if self.path == "/v1/models":
            self._json(
                200,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": "qwen2.5:3b",
                            "object": "model",
                            "owned_by": "local",
                        }
                    ],
                },
            )
            return

        self._json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)

        if self.path in ("/api/generate", "/api/chat"):
            self._json(
                200,
                {
                    "model": "qwen2.5:3b",
                    "response": "LocalDevStack CI",
                    "message": {"role": "assistant", "content": "LocalDevStack CI"},
                    "done": True,
                },
            )
            return

        if self.path == "/v1/chat/completions":
            self._json(
                200,
                {
                    "id": "chatcmpl-ci",
                    "object": "chat.completion",
                    "choices": [
                        {
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": "LocalDevStack CI",
                            },
                            "finish_reason": "stop",
                        }
                    ],
                },
            )
            return

        self._json(404, {"error": "not found"})

    def log_message(self, format, *args):
        return


ThreadingHTTPServer(("0.0.0.0", 11434), Handler).serve_forever()
