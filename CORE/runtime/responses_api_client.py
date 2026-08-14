from __future__ import annotations

import json
import os
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any


def fail(code: str) -> int:
    print(json.dumps({"ok": False, "code": code}, separators=(",", ":")))
    return 1


def completed_response_from_sse_block(block: list[str]) -> dict[str, Any] | None:
    payload_lines = [line[5:].lstrip() for line in block if line.startswith("data:")]
    if not payload_lines:
        return None
    payload = "\n".join(payload_lines).strip()
    if not payload or payload == "[DONE]":
        return None
    try:
        value = json.loads(payload)
    except json.JSONDecodeError:
        raise ValueError("RESPONSES_EVENT_INVALID") from None
    if not isinstance(value, dict):
        raise ValueError("RESPONSES_EVENT_INVALID")
    event_type = str(value.get("type", ""))
    if event_type == "response.completed":
        candidate = value.get("response", value)
        if isinstance(candidate, dict):
            return candidate
        raise ValueError("RESPONSES_RESPONSE_INVALID")
    if event_type in {"response.failed", "response.incomplete"}:
        raise ValueError("RESPONSES_RESPONSE_FAILED")
    return None


def response_from_stream(raw: str) -> dict[str, Any]:
    for block in raw.replace("\r\n", "\n").split("\n\n"):
        completed = completed_response_from_sse_block(block.split("\n"))
        if completed is not None:
            return completed
    raise ValueError("RESPONSES_RESPONSE_INCOMPLETE")


def response_from_stream_reader(response: Any) -> dict[str, Any]:
    block: list[str] = []
    while True:
        raw_line = response.readline()
        if not raw_line:
            break
        line = raw_line.decode("utf-8", errors="replace").rstrip("\r\n")
        if line:
            block.append(line)
            continue
        completed = completed_response_from_sse_block(block)
        block = []
        if completed is not None:
            return completed
    completed = completed_response_from_sse_block(block)
    if completed is not None:
        return completed
    raise ValueError("RESPONSES_RESPONSE_INCOMPLETE")


def response_text(response: dict[str, Any]) -> str:
    text = response.get("output_text")
    if isinstance(text, str) and text.strip():
        return text
    for output in response.get("output", []):
        if not isinstance(output, dict) or output.get("type") != "message":
            continue
        for content in output.get("content", []):
            if not isinstance(content, dict) or content.get("type") not in {"output_text", "text", None, ""}:
                continue
            value = content.get("text")
            if isinstance(value, str) and value.strip():
                return value
            if isinstance(value, dict) and isinstance(value.get("value"), str) and value["value"].strip():
                return value["value"]
    for choice in response.get("choices", []):
        if isinstance(choice, dict) and isinstance(choice.get("message"), dict):
            value = choice["message"].get("content")
            if isinstance(value, str) and value.strip():
                return value
    raise ValueError("RESPONSES_RESPONSE_INVALID")


def is_loopback_endpoint(endpoint: str) -> bool:
    parsed = urllib.parse.urlsplit(endpoint)
    return parsed.scheme == "http" and (parsed.hostname or "").lower() in {"127.0.0.1", "localhost", "::1"}


def is_local_codex_responses_endpoint(endpoint: str) -> bool:
    parsed = urllib.parse.urlsplit(endpoint)
    return is_loopback_endpoint(endpoint) and parsed.path.rstrip("/").lower() == "/codex/v1/responses"


def request_headers(endpoint: str, api_key: str) -> dict[str, str]:
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json; charset=utf-8",
        "Accept": "text/event-stream, application/json",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    }
    if is_local_codex_responses_endpoint(endpoint):
        isolated_id = f"super-brain-eval-{uuid.uuid4().hex}"
        # Match Codex Desktop's native stream contract at Atoapi's Codex route.
        # The client still accepts a JSON terminal response defensively below.
        headers["Accept"] = "text/event-stream"
        # Atoapi forwards this capability header to the configured Codex
        # provider. Without it, the local route is not wire-equivalent to a
        # native Responses client.
        headers["OpenAI-Beta"] = "responses=v1"
        headers["x-codex-turn-metadata"] = json.dumps(
            {"session_id": isolated_id, "thread_id": isolated_id, "request_kind": "turn"},
            separators=(",", ":"),
        )
    return headers


def normalize_responses_endpoint(base_url: str) -> str:
    parsed = urllib.parse.urlsplit(base_url.strip())
    if not parsed.scheme or not parsed.netloc:
        raise ValueError("CODEX_PROVIDER_URL_INVALID")
    if parsed.scheme != "https" and not is_loopback_endpoint(base_url):
        raise ValueError("CODEX_PROVIDER_URL_INSECURE")
    path = parsed.path.rstrip("/")
    lowered = path.lower()
    if lowered.endswith("/v1/responses"):
        next_path = path
    elif lowered.endswith("/responses"):
        next_path = path[: -len("/responses")] + "/v1/responses"
    elif lowered.endswith("/v1"):
        next_path = path + "/responses"
    else:
        next_path = path + "/v1/responses"
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, next_path or "/v1/responses", "", ""))


def resolve_codex_desktop_connection(config_path: str) -> dict[str, Any]:
    path = Path(config_path)
    if not path.is_file():
        return {"ok": False, "code": "CODEX_CONFIG_NOT_FOUND"}
    try:
        config = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError, UnicodeError):
        return {"ok": False, "code": "CODEX_CONFIG_PARSE_FAILED"}
    provider_name = config.get("model_provider")
    providers = config.get("model_providers")
    if not isinstance(provider_name, str) or not isinstance(providers, dict):
        return {"ok": False, "code": "CODEX_PROVIDER_MISSING"}
    provider = providers.get(provider_name)
    if not isinstance(provider, dict):
        return {"ok": False, "code": "CODEX_PROVIDER_MISSING"}
    if str(provider.get("wire_api", "")).strip().lower() != "responses":
        return {"ok": False, "code": "CODEX_PROVIDER_WIRE_API_UNSUPPORTED"}
    base_url = provider.get("base_url")
    api_key = provider.get("experimental_bearer_token")
    if not isinstance(base_url, str) or not base_url.strip():
        return {"ok": False, "code": "CODEX_PROVIDER_URL_MISSING"}
    if not isinstance(api_key, str) or not api_key.strip():
        return {"ok": False, "code": "CODEX_PROVIDER_CREDENTIAL_MISSING"}
    try:
        endpoint = normalize_responses_endpoint(base_url)
    except ValueError as exc:
        return {"ok": False, "code": str(exc)}
    return {"ok": True, "responsesUrl": endpoint, "apiKey": api_key.strip()}


def parse_response_body(raw: str, content_type: str) -> dict[str, Any]:
    normalized_type = content_type.lower().split(";", 1)[0].strip()
    stripped = raw.lstrip()
    if normalized_type == "text/html" or stripped.lower().startswith(("<!doctype html", "<html")):
        raise ValueError("RESPONSES_HTML_REJECTED")
    if stripped.startswith("{"):
        value = json.loads(raw)
        response = value.get("response", value) if isinstance(value, dict) else None
        if not isinstance(response, dict):
            raise ValueError("RESPONSES_RESPONSE_INVALID")
        return response
    return response_from_stream(raw)


def request_once(endpoint: str, api_key: str, payload: dict[str, Any], direct: bool, timeout: int) -> dict[str, Any]:
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=data,
        method="POST",
        headers=request_headers(endpoint, api_key),
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({})) if direct else urllib.request.build_opener()
    with opener.open(request, timeout=timeout) as result:
        content_type = result.headers.get_content_type()
        if content_type.lower() == "text/html":
            raise ValueError("RESPONSES_HTML_REJECTED")
        if content_type.lower() == "text/event-stream":
            return response_from_stream_reader(result)
        return parse_response_body(result.read().decode("utf-8", errors="replace"), content_type)


def resolve_codex_config_mode(config_path: str) -> int:
    result = resolve_codex_desktop_connection(config_path)
    print(json.dumps(result, separators=(",", ":")))
    return 0 if result.get("ok") is True else 1


def bounded_timeout(value: object) -> int | None:
    try:
        return min(300, max(5, int(value)))
    except (TypeError, ValueError):
        return None


def read_stdin_json() -> object:
    """Read the private bridge envelope as UTF-8 regardless of Windows code page."""
    binary_input = getattr(sys.stdin, "buffer", None)
    if binary_input is None:
        return json.loads(sys.stdin.readline())
    raw = binary_input.readline()
    if isinstance(raw, bytes):
        return json.loads(raw.decode("utf-8"))
    return json.loads(raw)


def execute_request(endpoint: str, api_key: str, payload: object, timeout: int | None) -> int:
    if not endpoint or not api_key or timeout is None:
        return fail("RESPONSES_CLIENT_CONFIGURATION_MISSING")
    if not isinstance(payload, dict):
        return fail("RESPONSES_CLIENT_INPUT_INVALID")
    try:
        response = request_once(endpoint, api_key, payload, direct=is_loopback_endpoint(endpoint), timeout=timeout)
        model = response.get("model")
        response_id = response.get("id")
        if not isinstance(model, str) or not model.strip():
            return fail("RESPONSES_REPORTED_MODEL_MISSING")
        if not isinstance(response_id, str) or not response_id.strip():
            return fail("RESPONSES_ID_MISSING")
        # The child-process protocol is ASCII JSON so its result remains stable
        # even when Python inherits a legacy Windows console code page.
        print(json.dumps({"ok": True, "response": {"id": response_id, "model": model, "output_text": response_text(response)}}, ensure_ascii=True, separators=(",", ":")))
        return 0
    except urllib.error.HTTPError as exc:
        return fail(f"RESPONSES_HTTP_{exc.code}")
    except TimeoutError:
        return fail("RESPONSES_CLIENT_TIMEOUT")
    except ValueError as exc:
        return fail(str(exc))
    except Exception:
        return fail("RESPONSES_TRANSPORT_FAILED")


def environment_mode() -> int:
    endpoint = os.environ.get("SUPER_BRAIN_RESPONSE_CLIENT_ENDPOINT", "").strip()
    api_key = os.environ.get("SUPER_BRAIN_RESPONSE_CLIENT_API_KEY", "").strip()
    timeout = bounded_timeout(os.environ.get("SUPER_BRAIN_RESPONSE_CLIENT_TIMEOUT_SECONDS", "120"))
    try:
        payload = read_stdin_json()
    except (json.JSONDecodeError, UnicodeDecodeError, OSError):
        return fail("RESPONSES_CLIENT_INPUT_INVALID")
    return execute_request(endpoint, api_key, payload, timeout)


def stdin_envelope_mode() -> int:
    try:
        envelope = read_stdin_json()
    except (json.JSONDecodeError, UnicodeDecodeError, OSError):
        return fail("RESPONSES_CLIENT_INPUT_INVALID")
    if not isinstance(envelope, dict):
        return fail("RESPONSES_CLIENT_INPUT_INVALID")
    endpoint = envelope.get("endpoint")
    api_key = envelope.get("apiKey")
    if not isinstance(endpoint, str) or not isinstance(api_key, str):
        return fail("RESPONSES_CLIENT_CONFIGURATION_MISSING")
    return execute_request(endpoint.strip(), api_key.strip(), envelope.get("payload"), bounded_timeout(envelope.get("timeoutSeconds")))


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--resolve-codex-config":
        return resolve_codex_config_mode(sys.argv[2])
    if len(sys.argv) == 2 and sys.argv[1] == "--stdin-envelope":
        return stdin_envelope_mode()
    if len(sys.argv) != 1:
        return fail("RESPONSES_CLIENT_ARGUMENT_INVALID")
    return environment_mode()


if __name__ == "__main__":
    raise SystemExit(main())
