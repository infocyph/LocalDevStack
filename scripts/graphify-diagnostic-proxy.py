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
_GRAPH_SCHEMA = {
    "type": "object",
    "required": ["nodes", "edges", "hyperedges"],
    "properties": {
        "nodes": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["id", "label", "file_type", "source_file"],
                "properties": {
                    "id": {"type": "string"},
                    "label": {"type": "string"},
                    "file_type": {
                        "type": "string",
                        "enum": ["code", "document", "paper", "image", "rationale", "concept"],
                    },
                    "source_file": {"type": "string"},
                    "source_location": {"type": ["string", "null"]},
                    "source_url": {"type": ["string", "null"]},
                    "captured_at": {"type": ["string", "null"]},
                    "author": {"type": ["string", "null"]},
                    "contributor": {"type": ["string", "null"]},
                    "rationale": {"type": ["string", "null"]},
                },
            },
        },
        "edges": {
            "type": "array",
            "items": {
                "type": "object",
                "required": [
                    "source", "target", "relation", "confidence",
                    "confidence_score", "source_file", "weight",
                ],
                "properties": {
                    "source": {"type": "string"},
                    "target": {"type": "string"},
                    "relation": {
                        "type": "string",
                        "enum": [
                            "calls", "implements", "references", "cites",
                            "conceptually_related_to", "shares_data_with",
                            "semantically_similar_to", "rationale_for",
                        ],
                    },
                    "confidence": {
                        "type": "string",
                        "enum": ["EXTRACTED", "INFERRED", "AMBIGUOUS"],
                    },
                    "confidence_score": {"type": "number"},
                    "source_file": {"type": "string"},
                    "source_location": {"type": ["string", "null"]},
                    "weight": {"type": "number"},
                },
            },
        },
        "hyperedges": {
            "type": "array",
            "items": {
                "type": "object",
                "required": [
                    "id", "label", "nodes", "relation", "confidence",
                    "confidence_score", "source_file",
                ],
                "properties": {
                    "id": {"type": "string"},
                    "label": {"type": "string"},
                    "nodes": {"type": "array", "items": {"type": "string"}},
                    "relation": {
                        "type": "string",
                        "enum": ["participate_in", "implement", "form"],
                    },
                    "confidence": {
                        "type": "string",
                        "enum": ["EXTRACTED", "INFERRED"],
                    },
                    "confidence_score": {"type": "number"},
                    "source_file": {"type": "string"},
                },
            },
        },
    },
}

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


def parse_graph_content(content: str | None) -> dict[str, list[dict[str, Any]]] | None:
    """Return a structurally valid graph fragment, including an all-empty fragment."""
    if content is None or not content.strip():
        return None
    for candidate in _json_candidates(content):
        try:
            parsed = json.loads(candidate)
        except (json.JSONDecodeError, TypeError):
            continue
        if not isinstance(parsed, dict):
            continue

        graph: dict[str, list[dict[str, Any]]] = {}
        for key in _GRAPH_KEYS:
            value = parsed.get(key)
            if not isinstance(value, list) or any(not isinstance(entry, dict) for entry in value):
                break
            graph[key] = value
        else:
            return graph
    return None


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



_GRAPH_TOOL = {
    "type": "function",
    "function": {
        "name": "submit_graph",
        "description": "Submit the extracted Graphify knowledge-graph fragment. Call exactly once.",
        "parameters": _GRAPH_SCHEMA,
    },
}


def _build_ollama_schema_request(body: bytes) -> bytes | None:
    try:
        request = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(request, dict):
        return None

    request = dict(request)
    request["stream"] = False
    request["temperature"] = 0
    request["response_format"] = {
        "type": "json_schema",
        "json_schema": {
            "name": "graphify_fragment",
            "strict": True,
            "schema": _GRAPH_SCHEMA,
        },
    }
    return json.dumps(request, ensure_ascii=False).encode("utf-8")


def _build_tool_recovery_request(body: bytes) -> bytes | None:
    try:
        request = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(request, dict):
        return None

    messages = request.get("messages")
    if not isinstance(messages, list):
        return None

    request = dict(request)
    request["tools"] = [_GRAPH_TOOL]
    # FastFlow v1.0.6 treats unsupported tool_choice modes as auto, so the
    # explicit instruction is the enforcement mechanism for Qwen3.5.
    request["tool_choice"] = "auto"
    request["stream"] = False

    amended = []
    recovery_suffix = (
        "\n\nSTRUCTURED RECOVERY: Do not emit the graph as assistant text. "
        "Call the submit_graph tool exactly once. Put the complete extraction "
        "fragment into its nodes, edges, and hyperedges arguments. Do not add "
        "new facts; follow the original Graphify schema and source_file rules."
    )
    injected = False
    for message in messages:
        if not isinstance(message, dict):
            amended.append(message)
            continue
        copied = dict(message)
        if (
            not injected
            and copied.get("role") == "system"
            and isinstance(copied.get("content"), str)
            and "graphify semantic extraction agent" in copied["content"]
        ):
            copied["content"] += recovery_suffix
            injected = True
        amended.append(copied)
    if not injected:
        amended.insert(0, {"role": "system", "content": recovery_suffix.strip()})
    request["messages"] = amended
    return json.dumps(request, ensure_ascii=False).encode("utf-8")


def _coerce_graph_array(value: Any) -> list[dict[str, Any]] | None:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError:
            return None
    if not isinstance(value, list):
        return None
    if any(not isinstance(entry, dict) for entry in value):
        return None
    return value


def _extract_graph_tool_result(body: bytes) -> dict[str, Any] | None:
    try:
        response = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(response, dict):
        return None

    choices = response.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        return None
    message = choices[0].get("message")
    if not isinstance(message, dict):
        return None
    tool_calls = message.get("tool_calls")
    if not isinstance(tool_calls, list):
        return None

    for call in tool_calls:
        if not isinstance(call, dict):
            continue
        function = call.get("function")
        if not isinstance(function, dict) or function.get("name") != "submit_graph":
            continue
        arguments = function.get("arguments")
        if isinstance(arguments, str):
            try:
                arguments = json.loads(arguments)
            except json.JSONDecodeError:
                continue
        if not isinstance(arguments, dict):
            continue

        graph: dict[str, Any] = {}
        for key in _GRAPH_KEYS:
            value = _coerce_graph_array(arguments.get(key))
            if value is None:
                break
            graph[key] = value
        else:
            return graph
    return None


def _replace_response_content(body: bytes, graph: dict[str, Any]) -> bytes | None:
    try:
        response = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(response, dict):
        return None
    choices = response.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        return None

    response = dict(response)
    choices = [dict(choice) if isinstance(choice, dict) else choice for choice in choices]
    first = choices[0]
    message = first.get("message")
    if not isinstance(message, dict):
        message = {}
    else:
        message = dict(message)
    message["role"] = "assistant"
    message["content"] = json.dumps(graph, ensure_ascii=False, separators=(",", ":"))
    message.pop("tool_calls", None)
    message.pop("reasoning_content", None)
    message.pop("reasoning", None)
    message.pop("thinking", None)
    first["message"] = message
    first["finish_reason"] = "stop"
    choices[0] = first
    response["choices"] = choices
    return json.dumps(response, ensure_ascii=False).encode("utf-8")


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
    provider: str = ""
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

        is_chat = self.command == "POST" and self.path.rstrip("/").endswith("/v1/chat/completions")
        metadata = _request_metadata(body) if is_chat else {}
        extraction_request = bool(metadata.get("_extraction_request"))

        upstream_body = body
        structured_primary = ""
        if extraction_request and self.provider == "fastflow":
            candidate = _build_tool_recovery_request(body)
            if candidate is not None:
                upstream_body = candidate
                structured_primary = "fastflow-tool"
        elif extraction_request and self.provider == "ollama":
            candidate = _build_ollama_schema_request(body)
            if candidate is not None:
                upstream_body = candidate
                structured_primary = "ollama-schema"

        upstream_url = self.upstream.rstrip("/") + self.path
        request = urllib.request.Request(
            upstream_url,
            data=upstream_body if self.command not in ("GET", "HEAD") else None,
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

        if is_chat and extraction_request:
            if structured_primary == "fastflow-tool" and 200 <= status < 300:
                graph = _extract_graph_tool_result(response_body)
                if graph is not None:
                    replacement = _replace_response_content(response_body, graph)
                    if replacement is not None:
                        response_body = replacement
                        print(
                            "[lds graphify diagnostic] structured FastFlow graph via submit_graph tool: "
                            f"model={metadata.get('model')}; think={metadata.get('think')}; "
                            f"nodes={len(graph['nodes'])}; edges={len(graph['edges'])}; "
                            f"hyperedges={len(graph['hyperedges'])}",
                            file=sys.stderr,
                            flush=True,
                        )
                    else:
                        response_body = self._fallback_freeform(body)
                else:
                    response_body = self._fallback_freeform(body)
            elif structured_primary == "ollama-schema" and 200 <= status < 300:
                _meta, content = _response_metadata(response_body)
                graph = parse_graph_content(content)
                if graph is None:
                    response_body = self._fallback_freeform(body)
                else:
                    print(
                        "[lds graphify diagnostic] structured Ollama graph via response_format schema: "
                        f"model={metadata.get('model')}; reasoning_effort={metadata.get('reasoning_effort')}; "
                        f"nodes={len(graph['nodes'])}; edges={len(graph['edges'])}; "
                        f"hyperedges={len(graph['hyperedges'])}",
                        file=sys.stderr,
                        flush=True,
                    )
            else:
                response_body = self._inspect_and_recover_chat_response(body, response_body, status)

        self.send_response(status)
        for name, value in response_headers.items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(response_body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(response_body)

    def _fallback_freeform(self, original_body: bytes) -> bytes:
        fallback = self._post_upstream(original_body)
        if fallback is None:
            return b'{"error":{"message":"Structured Graphify extraction failed and free-form fallback was unavailable"}}'
        print(
            "[lds graphify diagnostic] submit_graph primary extraction did not yield a usable graph; "
            "falling back to the original free-form Graphify request",
            file=sys.stderr,
            flush=True,
        )
        return self._inspect_and_recover_chat_response(original_body, fallback, 200)

    def _post_upstream(self, body: bytes) -> bytes | None:
        request = urllib.request.Request(
            self.upstream.rstrip("/") + "/v1/chat/completions",
            data=body,
            headers={
                "Content-Type": "application/json",
                "Authorization": self.headers.get("Authorization", "Bearer local"),
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=1900) as response:
                if response.status < 200 or response.status >= 300:
                    return None
                return response.read()
        except Exception:
            return None

    def _inspect_and_recover_chat_response(
        self, request_body: bytes, response_body: bytes, status: int
    ) -> bytes:
        req = _request_metadata(request_body)
        resp, content = _response_metadata(response_body)
        extraction_request = req.pop("_extraction_request", False)
        if status < 200 or status >= 300 or not extraction_request:
            return response_body

        suspect, reason = classify_graph_content(content)
        if not suspect:
            return response_body

        original_reason = reason
        recovery = _build_tool_recovery_request(request_body)
        recovered_graph = None
        recovered_response = None
        if recovery is not None and req.get("think", "<omitted>") != "<omitted>":
            recovered_response = self._post_upstream(recovery)
            if recovered_response is not None:
                recovered_graph = _extract_graph_tool_result(recovered_response)

        if recovered_graph is not None and recovered_response is not None:
            replacement = _replace_response_content(recovered_response, recovered_graph)
            if replacement is not None:
                recovered_meta, _ = _response_metadata(replacement)
                print(
                    "[lds graphify diagnostic] recovered malformed FastFlow graph via submit_graph tool: "
                    f"model={req.get('model')}; think={req.get('think')}; "
                    f"nodes={len(recovered_graph['nodes'])}; edges={len(recovered_graph['edges'])}; "
                    f"hyperedges={len(recovered_graph['hyperedges'])}; "
                    f"completion_tokens={recovered_meta.get('completion_tokens')}",
                    file=sys.stderr,
                    flush=True,
                )
                return replacement

        reason = original_reason
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
        if recovery is not None:
            print(
                "[lds graphify diagnostic] structured submit_graph recovery did not yield a usable graph; "
                "returning the original response so Graphify can apply its normal retry policy",
                file=sys.stderr,
                flush=True,
            )
        return response_body

    do_GET = _forward
    do_HEAD = _forward
    do_POST = _forward


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--provider", required=True, choices=("fastflow", "ollama"))
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--log-file", required=True)
    parser.add_argument("--preview-chars", type=int, default=4096)
    args = parser.parse_args()

    DiagnosticHandler.upstream = args.upstream
    DiagnosticHandler.provider = args.provider
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
