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
                            "name": "qwen3.5:9b",
                            "model": "qwen3.5:9b",
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
                            "id": "qwen3.5:9b",
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
        raw = self.rfile.read(length) if length else b""
        try:
            request = json.loads(raw.decode()) if raw else {}
        except (UnicodeDecodeError, json.JSONDecodeError):
            request = {}

        if self.path in ("/api/generate", "/api/chat"):
            self._json(
                200,
                {
                    "model": "qwen3.5:9b",
                    "response": "LocalDevStack CI",
                    "message": {"role": "assistant", "content": "LocalDevStack CI"},
                    "done": True,
                },
            )
            return

        if self.path == "/v1/chat/completions":
            messages = request.get("messages", []) if isinstance(request, dict) else []
            graphify = any(
                isinstance(message, dict)
                and message.get("role") == "system"
                and "graphify semantic extraction agent" in str(message.get("content", ""))
                for message in messages
            )
            content = "LocalDevStack CI"
            if graphify:
                content = json.dumps(
                    {
                        "nodes": [
                            {
                                "id": "readme_document",
                                "label": "README Document",
                                "file_type": "document",
                                "source_file": "README.md",
                            }
                        ],
                        "edges": [],
                        "hyperedges": [],
                    }
                )
            self._json(
                200,
                {
                    "id": "chatcmpl-ci",
                    "object": "chat.completion",
                    "model": request.get("model", "qwen3.5:9b") if isinstance(request, dict) else "qwen3.5:9b",
                    "choices": [
                        {
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": content,
                            },
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 50,
                        "completion_tokens": 20,
                        "total_tokens": 70,
                    },
                },
            )
            return

        self._json(404, {"error": "not found"})

    def log_message(self, format, *args):
        return


ThreadingHTTPServer(("0.0.0.0", 11434), Handler).serve_forever()
