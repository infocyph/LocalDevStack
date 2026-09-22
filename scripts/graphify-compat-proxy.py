#!/usr/bin/env python3
"""LocalDevStack Graphify compatibility reverse proxy.

Adapts provider-native structured output to the OpenAI-compatible response shape
Graphify v8 consumes. Optional diagnostics report only suspect completions; request
prompts/source content are never logged.
"""
from __future__ import annotations

import argparse
import json
import re
import socket
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

_GRAPH_KEYS = ("nodes", "edges", "hyperedges")
_STRUCTURED_MAX_TOKENS = 8192

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
                            "semantically_similar_to",
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


def _build_ollama_schema_request(body: bytes, maximum: int = _STRUCTURED_MAX_TOKENS) -> bytes | None:
    try:
        request = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(request, dict):
        return None

    request = dict(request)
    request["stream"] = False
    request["temperature"] = 0
    request.pop("max_tokens", None)
    request["max_completion_tokens"] = _bounded_completion_cap(request, maximum)
    request["response_format"] = {
        "type": "json_schema",
        "json_schema": {
            "name": "graphify_fragment",
            "strict": True,
            "schema": _GRAPH_SCHEMA,
        },
    }
    return json.dumps(request, ensure_ascii=False).encode("utf-8")


def _bounded_completion_cap(request: dict[str, Any], maximum: int = _STRUCTURED_MAX_TOKENS) -> int:
    raw = request.get("max_completion_tokens", request.get("max_tokens", _STRUCTURED_MAX_TOKENS))
    try:
        cap = int(raw)
    except (TypeError, ValueError):
        cap = _STRUCTURED_MAX_TOKENS
    return max(1, min(cap, maximum))


def _build_tool_recovery_request(body: bytes, maximum: int = _STRUCTURED_MAX_TOKENS) -> bytes | None:
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
    # FastFlow currently supports tool_choice=auto|none only. The explicit
    # system instruction is therefore what makes submit_graph mandatory.
    request["tool_choice"] = "auto"
    # FastFlow's Qwen3.5 streaming parser emits a complete tool-call delta as
    # soon as </tool_call>/</function> is parsed. Using streaming here avoids
    # waiting for model EOS on the non-stream path.
    request["stream"] = True
    request["temperature"] = 0
    request.pop("max_tokens", None)
    request["max_completion_tokens"] = _bounded_completion_cap(request, maximum)

    amended = []
    recovery_suffix = (
        "\n\nSTRUCTURED OUTPUT: Do not emit the graph as ordinary assistant text. "
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


def _decode_jsonish(value: Any) -> Any:
    """Decode nested JSON strings produced by OpenAI-compatible tool adapters."""
    current = value
    for _ in range(3):
        if not isinstance(current, str):
            break
        stripped = current.strip()
        if not stripped:
            break
        try:
            current = json.loads(stripped)
        except json.JSONDecodeError:
            break
    return current


def _coerce_graph_array(value: Any) -> list[dict[str, Any]] | None:
    value = _decode_jsonish(value)
    if not isinstance(value, list):
        return None
    if any(not isinstance(entry, dict) for entry in value):
        return None
    return value


def _coerce_graph_object(value: Any) -> dict[str, Any] | None:
    value = _decode_jsonish(value)
    if not isinstance(value, dict):
        return None

    # Some OpenAI-compatible servers wrap the function payload one level deeper.
    for wrapper in ("arguments", "graph", "payload", "data"):
        if wrapper in value and not all(key in value for key in _GRAPH_KEYS):
            nested = _decode_jsonish(value.get(wrapper))
            if isinstance(nested, dict):
                value = nested
                break

    graph: dict[str, Any] = {}
    for key in _GRAPH_KEYS:
        array = _coerce_graph_array(value.get(key))
        if array is None:
            return None
        graph[key] = array
    return graph


def _tool_call_candidates(message: dict[str, Any]) -> list[dict[str, Any]]:
    calls = message.get("tool_calls")
    if isinstance(calls, list):
        return [call for call in calls if isinstance(call, dict)]

    single = message.get("tool_call")
    if isinstance(single, dict):
        return [single]
    return []


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

    for call in _tool_call_candidates(message):
        function = call.get("function")
        if isinstance(function, dict):
            name = str(function.get("name", "")).strip()
            arguments = function.get("arguments")
        else:
            # Tolerate flatter adapters that place name/arguments on the call.
            name = str(call.get("name", "")).strip()
            arguments = call.get("arguments")

        graph = _coerce_graph_object(arguments)
        if graph is None:
            continue

        # submit_graph is the only tool we provide. Accept a structurally valid
        # graph even if FastFlow/Qwen adds harmless whitespace/name drift.
        if not name or name == "submit_graph" or len(_tool_call_candidates(message)) == 1:
            return graph

    return None


def _extract_fastflow_structured_graph(body: bytes) -> dict[str, Any] | None:
    graph = _extract_graph_tool_result(body)
    if graph is not None:
        return graph
    _meta, content = _response_metadata(body)
    return parse_graph_content(content)


def _normalized_usage(usage: Any) -> dict[str, int]:
    """Return OpenAI usage counters with integers even when a stream omits the tail event."""
    if not isinstance(usage, dict):
        usage = {}

    def _counter(name: str) -> int:
        value = usage.get(name, 0)
        return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0

    prompt_tokens = _counter("prompt_tokens")
    completion_tokens = _counter("completion_tokens")
    total_tokens = _counter("total_tokens")
    if total_tokens == 0 and (prompt_tokens or completion_tokens):
        total_tokens = prompt_tokens + completion_tokens

    return {
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": total_tokens,
    }


def _normalize_response_usage(body: bytes) -> bytes:
    """Ensure an OpenAI-compatible completion never exposes null usage counters."""
    try:
        response = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return body
    if not isinstance(response, dict):
        return body
    response = dict(response)
    response["usage"] = _normalized_usage(response.get("usage"))
    return json.dumps(response, ensure_ascii=False).encode("utf-8")


def _fastflow_stream_completion(upstream_response, model: str | None) -> bytes:
    """Collapse FastFlow SSE into one OpenAI completion, returning on a tool call."""
    content_parts: list[str] = []
    last_id = "chatcmpl-lds-fastflow"
    finish_reason = "stop"
    usage: dict[str, Any] = {}

    while True:
        raw_line = upstream_response.readline()
        if not raw_line:
            break
        try:
            line = raw_line.decode("utf-8", errors="replace").strip()
        except AttributeError:
            line = str(raw_line).strip()
        if not line.startswith("data:"):
            continue

        payload = line[5:].strip()
        if not payload:
            continue
        if payload == "[DONE]":
            break

        try:
            event = json.loads(payload)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue

        if isinstance(event.get("id"), str) and event["id"]:
            last_id = event["id"]
        if isinstance(event.get("usage"), dict):
            usage = event["usage"]

        choices = event.get("choices")
        if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
            continue
        choice = choices[0]
        if isinstance(choice.get("finish_reason"), str):
            finish_reason = choice["finish_reason"]

        delta = choice.get("delta")
        if not isinstance(delta, dict):
            continue

        content = delta.get("content")
        if isinstance(content, str) and content:
            content_parts.append(content)

        calls = delta.get("tool_calls")
        if isinstance(calls, list) and calls:
            normalized_calls = [call for call in calls if isinstance(call, dict)]
            if normalized_calls:
                # FastFlow emits the complete function arguments in TOOL_DONE,
                # not incremental argument fragments. Stop reading immediately
                # so a model that fails to emit EOS cannot hold Graphify open.
                response = {
                    "id": last_id,
                    "object": "chat.completion",
                    "model": model,
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": "".join(content_parts) or None,
                            "tool_calls": normalized_calls,
                        },
                        "finish_reason": "tool_calls",
                    }],
                    "usage": _normalized_usage(usage),
                }
                return json.dumps(response, ensure_ascii=False).encode("utf-8")

    response = {
        "id": last_id,
        "object": "chat.completion",
        "model": model,
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": "".join(content_parts),
            },
            "finish_reason": finish_reason,
        }],
        "usage": _normalized_usage(usage),
    }
    return json.dumps(response, ensure_ascii=False).encode("utf-8")


def _graphify_split_response(body: bytes, model: str | None) -> bytes:
    """Return a standard completion that makes Graphify bisect the current chunk."""
    try:
        response = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        response = {}
    if not isinstance(response, dict):
        response = {}

    out = dict(response)
    out.setdefault("id", "chatcmpl-lds-graphify-retry")
    out.setdefault("object", "chat.completion")
    if model:
        out["model"] = model
    out["choices"] = [{
        "index": 0,
        "finish_reason": "length",
        "message": {
            "role": "assistant",
            "content": '{"nodes":[],"edges":[],"hyperedges":[]}',
        },
    }]
    return json.dumps(out, ensure_ascii=False).encode("utf-8")


def _is_timeout_error(exc: BaseException) -> bool:
    if isinstance(exc, (TimeoutError, socket.timeout)):
        return True
    reason = getattr(exc, "reason", None)
    if isinstance(reason, (TimeoutError, socket.timeout)):
        return True
    return "timed out" in str(exc).lower() or "timeout" in str(exc).lower()


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
    # Preserve an upstream/synthetic length signal so Graphify's adaptive
    # retry layer bisects the offending chunk. Successful tool-call responses
    # are normalized to a regular completed assistant response.
    if first.get("finish_reason") != "length":
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


def _tool_call_summary(body: bytes) -> str:
    try:
        response = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return "unparseable-response"
    if not isinstance(response, dict):
        return "non-object-response"

    choices = response.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        return "no-choice"
    message = choices[0].get("message")
    if not isinstance(message, dict):
        return "no-message"

    summaries = []
    for call in _tool_call_candidates(message):
        function = call.get("function")
        if isinstance(function, dict):
            name = str(function.get("name", "")).strip() or "<empty>"
            args = _decode_jsonish(function.get("arguments"))
        else:
            name = str(call.get("name", "")).strip() or "<empty>"
            args = _decode_jsonish(call.get("arguments"))

        if isinstance(args, dict):
            summaries.append(f"{name}:keys={sorted(args.keys())}")
        else:
            summaries.append(f"{name}:args_type={type(args).__name__}")

    return "; ".join(summaries) if summaries else "no-tool-calls"


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


class GraphifyCompatHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream: str = ""
    provider: str = ""
    diagnostics: bool = False
    upstream_timeout: int = 1800
    structured_timeout: int = 300
    max_output_tokens: int = _STRUCTURED_MAX_TOKENS
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
            candidate = _build_tool_recovery_request(body, self.max_output_tokens)
            if candidate is not None:
                upstream_body = candidate
                structured_primary = "fastflow-tool"
        elif extraction_request and self.provider == "ollama":
            candidate = _build_ollama_schema_request(body, self.max_output_tokens)
            if candidate is not None:
                upstream_body = candidate
                structured_primary = "ollama-schema"

        upstream_url = self.upstream.rstrip("/") + self.path
        if structured_primary == "fastflow-tool":
            request_headers["Accept"] = "text/event-stream"

        request = urllib.request.Request(
            upstream_url,
            data=upstream_body if self.command not in ("GET", "HEAD") else None,
            headers=request_headers,
            method=self.command,
        )

        status = 502
        response_headers: dict[str, str] = {"Content-Type": "application/json"}
        response_body = b'{"error":{"message":"LocalDevStack Graphify compatibility proxy upstream failure"}}'

        try:
            request_timeout = self.structured_timeout if structured_primary else self.upstream_timeout
            with urllib.request.urlopen(request, timeout=request_timeout) as upstream_response:
                status = upstream_response.status
                if structured_primary == "fastflow-tool":
                    response_body = _fastflow_stream_completion(
                        upstream_response, metadata.get("model")
                    )
                    response_headers["Content-Type"] = "application/json"
                else:
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
            if structured_primary and _is_timeout_error(exc):
                status = 504
                response_body = json.dumps({
                    "error": {
                        "message": (
                            "LocalDevStack Graphify structured request timed out after "
                            f"{self.structured_timeout}s. Increase LDS_GRAPHIFY_STRUCTURED_TIMEOUT "
                            "or reduce --token-budget; timeout is not treated as output truncation."
                        )
                    }
                }).encode("utf-8")
                print(
                    "[lds graphify] structured provider request timed out after "
                    f"{self.structured_timeout}s; not bisecting because timeout is not truncation",
                    file=sys.stderr,
                    flush=True,
                )
            else:
                status = 502
                response_body = json.dumps(
                    {"error": {"message": f"LocalDevStack Graphify proxy upstream error: {exc}"}}
                ).encode("utf-8")

        if is_chat and extraction_request and 200 <= status < 300:
            if structured_primary == "fastflow-tool":
                graph = _extract_fastflow_structured_graph(response_body)
                if graph is not None:
                    replacement = _replace_response_content(response_body, graph)
                    if replacement is not None:
                        response_body = replacement
                        if self.diagnostics:
                            print(
                                "[lds graphify diagnostic] structured FastFlow graph via submit_graph tool: "
                                f"model={metadata.get('model')}; think={metadata.get('think')}; "
                                f"nodes={len(graph['nodes'])}; edges={len(graph['edges'])}; "
                                f"hyperedges={len(graph['hyperedges'])}",
                                file=sys.stderr,
                                flush=True,
                            )
                else:
                    self._diagnose_suspect_response(body, response_body, status)
                    response_body = _graphify_split_response(response_body, metadata.get("model"))
                    print(
                        "[lds graphify] FastFlow structured response unusable; "
                        "asking Graphify to split the chunk",
                        file=sys.stderr,
                        flush=True,
                    )
            elif structured_primary == "ollama-schema":
                _meta, content = _response_metadata(response_body)
                graph = parse_graph_content(content)
                if graph is None:
                    self._diagnose_suspect_response(body, response_body, status)
                    response_body = _graphify_split_response(response_body, metadata.get("model"))
                    print(
                        "[lds graphify] Ollama structured response unusable; "
                        "asking Graphify to split the chunk",
                        file=sys.stderr,
                        flush=True,
                    )
                elif self.diagnostics:
                    print(
                        "[lds graphify diagnostic] structured Ollama graph via response_format schema: "
                        f"model={metadata.get('model')}; reasoning_effort={metadata.get('reasoning_effort')}; "
                        f"nodes={len(graph['nodes'])}; edges={len(graph['edges'])}; "
                        f"hyperedges={len(graph['hyperedges'])}",
                        file=sys.stderr,
                        flush=True,
                    )

        if structured_primary and 200 <= status < 300:
            response_body = _normalize_response_usage(response_body)

        self.send_response(status)
        for name, value in response_headers.items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(response_body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(response_body)

    def _diagnose_suspect_response(
        self, request_body: bytes, response_body: bytes, status: int
    ) -> None:
        req = _request_metadata(request_body)
        req.pop("_extraction_request", None)
        resp, content = _response_metadata(response_body)
        suspect, reason = classify_graph_content(content)
        if not suspect:
            reason = "structured response did not contain a usable provider-native graph"

        tool_summary = _tool_call_summary(response_body)
        print(
            "[lds graphify] provider returned a suspect extraction response: "
            f"reason={reason}; model={req.get('model')}; finish_reason={resp.get('finish_reason')}; "
            f"tool_calls={tool_summary}",
            file=sys.stderr,
            flush=True,
        )

        if not self.diagnostics:
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
    parser.add_argument("--provider", required=True, choices=("fastflow", "ollama"))
    parser.add_argument("--diagnostics", choices=("on", "off"), default="off")
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--structured-timeout", type=int, default=300)
    parser.add_argument("--max-output-tokens", type=int, default=_STRUCTURED_MAX_TOKENS)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--log-file", required=True)
    parser.add_argument("--preview-chars", type=int, default=4096)
    args = parser.parse_args()

    GraphifyCompatHandler.upstream = args.upstream
    GraphifyCompatHandler.provider = args.provider
    GraphifyCompatHandler.diagnostics = args.diagnostics == "on"
    GraphifyCompatHandler.upstream_timeout = max(1, args.timeout)
    GraphifyCompatHandler.structured_timeout = max(1, args.structured_timeout)
    GraphifyCompatHandler.max_output_tokens = max(512, args.max_output_tokens)
    GraphifyCompatHandler.log_file = Path(args.log_file)
    GraphifyCompatHandler.preview_chars = max(256, args.preview_chars)

    server = ThreadingHTTPServer(("127.0.0.1", 0), GraphifyCompatHandler)
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
