#!/usr/bin/env python3
"""Local Graphify diagnostic reverse proxy.

Forwards OpenAI-compatible Graphify traffic to the active LocalDevStack LLM
without modifying request bodies. Only suspect chat-completion responses are
reported: empty content, malformed/non-graph JSON, or graph arrays containing
no usable object entries. Request prompts/source content are never logged.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

_GRAPH_KEYS = ("nodes", "edges", "hyperedges")
_FENCE_RE = re.compile(r"~~~[ \t]*([A-Za-z0-9_+-]*)[ \t]*\r?\n(.*?)~~~", re.S)


def _balanced_object(text: str, start: int) -> str | None:
    depth = 0
    in_string = False
    escape = False
    for index in range(start, len(text)):
        char = text[index]
        if escape:
            escape = False
            continue
        if char == "\\":
            escape = True
            continue
        if char == '"':
            in_string = not in_string
            continue
        if in_string:
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    return None


def _json_candidates(content: str):
    stripped = content.strip()
    if stripped:
        yield stripped
    # Avoid embedding Markdown fence delimiters in this helper's own source
    # contract; normalize them before matching.
    fenced = content.replace(chr(96) * 3, "~~~")
    for _lang, body in _FENCE_RE.findall(fenced):
        body = body.strip()
        if body:
            yield body
    start = content.find("{")
    seen = 0
    while start != -1 and seen < 128:
        candidate = _balanced_object(content, start)
        if candidate is not None:
            yield candidate
            seen += 1
        start = content.find("{", start + 1)


def classify_graph_content(content: str | None) -> tuple[bool, str]:
    """Return (suspect, reason), mirroring Graphify's hollow decision closely."""
    if content is None or not content.strip():
        return True, "empty assistant content"

    saw_json = False
    saw_graph_shape = False
    saw_wrong_shape = False

    for candidate in _json_candidates(content):
        try:
            parsed = json.loads(candidate)
        except (json.JSONDecodeError, TypeError):
            continue
        if not isinstance(parsed, dict):
            continue

        saw_json = True
        if not any(key in parsed for key in _GRAPH_KEYS):
            continue

        saw_graph_shape = True
        usable = False
        wrong_shape = False
        for key in _GRAPH_KEYS:
            value = parsed.get(key)
            if value is None:
                continue
            if not isinstance(value, list):
                wrong_shape = True
                continue
            if any(isinstance(entry, dict) for entry in value):
                usable = True
            if value and not any(isinstance(entry, dict) for entry in value):
                wrong_shape = True

        if usable:
            return False, "usable graph fragment"
        saw_wrong_shape = saw_wrong_shape or wrong_shape

    if saw_wrong_shape:
        return True, "graph arrays contain no usable object entries"
    if saw_graph_shape:
        return True, "valid but empty graph fragment"
    if any(f'"{key}"' in content for key in _GRAPH_KEYS):
        return True, "malformed graph JSON"
    if saw_json:
        return True, "JSON response has no graph fragment keys"
    return True, "response is not parseable as a graph JSON object"


def _request_metadata(body: bytes) -> dict[str, Any]:
    try:
        request = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}
    if not isinstance(request, dict):
        return {}

    messages = request.get("messages")
    extraction_request = False
    if isinstance(messages, list):
        for message in messages:
            if not isinstance(message, dict) or message.get("role") != "system":
                continue
            content = message.get("content")
            if isinstance(content, str) and "graphify semantic extraction agent" in content:
                extraction_request = True
                break

    return {
        "_extraction_request": extraction_request,
        "model": request.get("model"),
        "think": request.get("think", "<omitted>"),
        "reasoning_effort": request.get("reasoning_effort", "<omitted>"),
        "max_completion_tokens": request.get("max_completion_tokens", request.get("max_tokens")),
        "stream": request.get("stream"),
    }


def _response_metadata(body: bytes) -> tuple[dict[str, Any], str | None]:
    try:
        response = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}, None
    if not isinstance(response, dict):
        return {}, None

    choices = response.get("choices")
    choice = choices[0] if isinstance(choices, list) and choices and isinstance(choices[0], dict) else {}
    message = choice.get("message") if isinstance(choice.get("message"), dict) else {}
    usage = response.get("usage") if isinstance(response.get("usage"), dict) else {}

    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, str):
        content = None

    return {
        "finish_reason": choice.get("finish_reason"),
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "total_tokens": usage.get("total_tokens"),
    }, content


class DiagnosticHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream: str = ""
    log_file: Path
    preview_chars: int = 4096

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _forward(self) -> None:
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""

        request_headers = {}
        for name in ("Authorization", "Content-Type", "Accept", "User-Agent"):
            value = self.headers.get(name)
            if value:
                request_headers[name] = value

        upstream_url = self.upstream.rstrip("/") + self.path
        request = urllib.request.Request(
            upstream_url,
            data=body if self.command not in ("GET", "HEAD") else None,
            headers=request_headers,
            method=self.command,
        )

        status = 502
        response_headers: dict[str, str] = {"Content-Type": "application/json"}
        response_body = b'{"error":{"message":"LocalDevStack Graphify diagnostic proxy upstream failure"}}'

        try:
            with urllib.request.urlopen(request, timeout=1900) as upstream_response:
                status = upstream_response.status
                response_body = upstream_response.read()
                content_type = upstream_response.headers.get("Content-Type")
                if content_type:
                    response_headers["Content-Type"] = content_type
        except urllib.error.HTTPError as exc:
            status = exc.code
            response_body = exc.read()
            content_type = exc.headers.get("Content-Type") if exc.headers else None
            if content_type:
                response_headers["Content-Type"] = content_type
        except Exception as exc:
            response_body = json.dumps(
                {"error": {"message": f"Graphify diagnostic proxy upstream error: {exc}"}}
            ).encode("utf-8")

        if self.command == "POST" and self.path.rstrip("/").endswith("/v1/chat/completions"):
            self._inspect_chat_response(body, response_body, status)

        self.send_response(status)
        for name, value in response_headers.items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(response_body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(response_body)

    def _inspect_chat_response(self, request_body: bytes, response_body: bytes, status: int) -> None:
        req = _request_metadata(request_body)
        resp, content = _response_metadata(response_body)
        if status < 200 or status >= 300 or not req.pop("_extraction_request", False):
            return

        suspect, reason = classify_graph_content(content)
        if not suspect:
            return

        record = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "status": status,
            "reason": reason,
            **req,
            **resp,
            "assistant_content": content,
        }
        self.log_file.parent.mkdir(parents=True, exist_ok=True)
        with self.log_file.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")

        preview = (content or "")[: self.preview_chars]
        print(
            "[lds graphify diagnostic] suspect LLM response: "
            f"reason={reason}; model={req.get('model')}; "
            f"think={req.get('think')}; reasoning_effort={req.get('reasoning_effort')}; "
            f"finish_reason={resp.get('finish_reason')}; "
            f"prompt_tokens={resp.get('prompt_tokens')}; "
            f"completion_tokens={resp.get('completion_tokens')}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[lds graphify diagnostic] assistant content preview ({len(preview)}/{len(content or '')} chars): "
            f"{preview!r}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[lds graphify diagnostic] full suspect response logged to {self.log_file}",
            file=sys.stderr,
            flush=True,
        )

    do_GET = _forward
    do_HEAD = _forward
    do_POST = _forward


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--log-file", required=True)
    parser.add_argument("--preview-chars", type=int, default=4096)
    args = parser.parse_args()

    DiagnosticHandler.upstream = args.upstream
    DiagnosticHandler.log_file = Path(args.log_file)
    DiagnosticHandler.preview_chars = max(256, args.preview_chars)

    server = ThreadingHTTPServer(("127.0.0.1", 0), DiagnosticHandler)
    ready = Path(args.ready_file)
    ready.parent.mkdir(parents=True, exist_ok=True)
    ready.write_text(str(server.server_address[1]), encoding="utf-8")
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
