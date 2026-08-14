"""Launch the official LongMemEval-V2 harness with the isolated Super Brain adapter.

This entrypoint is intentionally outside the cloned official repository.  It
registers one additional memory type at process start and then calls the
unchanged official ``evaluation.harness`` module.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import sys
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Callable
from urllib.parse import urlparse


_ERROR_SECRET_PATTERNS = (
    (re.compile(r"(?i)\bbearer\s+[a-z0-9._~+/-]+=*"), "Bearer [REDACTED]"),
    (re.compile(r"(?i)\bsk-[a-z0-9_-]{8,}\b"), "[REDACTED_KEY]"),
    (
        re.compile(r"(?i)\b(api[_ -]?key|authorization|token|secret|password)\s*[:=]\s*[^\s,;]+"),
        r"\1=[REDACTED]",
    ),
    (re.compile(r"(?i)\bdata:[^\s,]+,[^\s]+"), "[REDACTED_DATA]"),
)
_SAFE_TERMINAL_DIAGNOSTIC_RE = re.compile(r"^[A-Za-z0-9_.:/-]{1,120}$")
_TRANSIENT_HTTP_STATUS_CODES = frozenset({408, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524})
_TRANSIENT_TERMINAL_ERROR_CODES = frozenset(
    {"rate_limit_exceeded", "server_error", "service_unavailable", "temporarily_unavailable", "timeout"}
)


def redact_http_error_summary(raw: str, *, max_chars: int = 360) -> str:
    """Return an allowlisted diagnostic without retaining an arbitrary error body."""

    candidate = ""
    parsed_json = False
    try:
        value = json.loads(raw)
    except (TypeError, ValueError, json.JSONDecodeError):
        value = None
    if isinstance(value, dict):
        parsed_json = True
        error = value.get("error")
        error = error if isinstance(error, dict) else value
        fragments: list[str] = []
        for field in ("code", "type", "param"):
            item = error.get(field) if isinstance(error, dict) else None
            if isinstance(item, str) and item.strip():
                fragments.append(f"{field}={item.strip()}")
        candidate = "; ".join(fragments)
    raw_text = str(raw or "").lstrip()
    if raw_text.lower().startswith(("<!doctype html", "<html", "<head", "<body")):
        return "upstream returned non-JSON HTML error"
    if not candidate:
        return "upstream JSON error detail unavailable" if parsed_json else "upstream returned non-JSON error"
    for pattern, replacement in _ERROR_SECRET_PATTERNS:
        candidate = pattern.sub(replacement, candidate)
    candidate = " ".join(candidate.split())
    if not candidate:
        return "upstream error detail unavailable"
    if len(candidate) > max_chars:
        return candidate[:max_chars].rstrip() + "..."
    return candidate


def _bounded_retry_count(value: int) -> int:
    return min(3, max(0, int(value)))


def _retry_delay_seconds(attempt: int) -> float:
    return min(4.0, 0.5 * (2**max(0, attempt)))


def _retry_notice(status_code: int | str, attempt: int, max_retries: int) -> None:
    print(
        f"[SUPER_BRAIN_RESPONSES_RETRY] status={status_code} retry={attempt}/{max_retries}",
        file=sys.stderr,
        flush=True,
    )


def _transient_terminal_error_code(error: RuntimeError) -> str:
    match = re.search(r"\berror\.code=([A-Za-z0-9_.:-]+)", str(error))
    if match is None:
        return ""
    code = match.group(1)
    return code if code in _TRANSIENT_TERMINAL_ERROR_CODES else ""


def _terminal_response_diagnostics(value: dict[str, Any], response: dict[str, Any] | None) -> set[str]:
    """Return a tiny allowlisted failure signature without retaining error text."""

    diagnostics: set[str] = set()
    for container in (value.get("error"), response.get("error") if isinstance(response, dict) else None):
        if not isinstance(container, dict):
            continue
        for field in ("type", "code", "param"):
            item = container.get(field)
            if not isinstance(item, str):
                continue
            normalized = item.strip()
            if _SAFE_TERMINAL_DIAGNOSTIC_RE.fullmatch(normalized):
                diagnostics.add(f"error.{field}={normalized}")
    return diagnostics


def _responses_endpoint(base_url: str | None, *, allowed_direct_base_url: str | None = None) -> str:
    """Resolve a local endpoint, or one explicitly bound HTTPS direct endpoint."""

    if not isinstance(base_url, str) or not base_url.strip():
        raise RuntimeError("Super Brain Responses bridge requires an explicit local Codex base URL.")
    normalized = base_url.rstrip("/")
    if normalized.endswith("/responses"):
        normalized = normalized[: -len("/responses")]
    parsed = urlparse(normalized)
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
    ):
        raise RuntimeError("Super Brain Responses bridge received an invalid base URL.")
    if parsed.scheme == "http" and parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise RuntimeError("Super Brain Responses bridge permits HTTP only for loopback Codex endpoints.")
    if parsed.path.rstrip("/").endswith("/codex/v1"):
        return normalized + "/responses"

    allowed = ""
    if isinstance(allowed_direct_base_url, str) and allowed_direct_base_url.strip():
        allowed = allowed_direct_base_url.rstrip("/")
        if allowed.endswith("/responses"):
            allowed = allowed[: -len("/responses")]
    allowed_parsed = urlparse(allowed)
    if (
        parsed.scheme == "https"
        and normalized == allowed
        and allowed_parsed.scheme == "https"
        and bool(allowed_parsed.hostname)
        and not allowed_parsed.username
        and not allowed_parsed.password
        and not allowed_parsed.query
        and not allowed_parsed.fragment
        and allowed_parsed.path.rstrip("/").endswith("/v1")
    ):
        return normalized + "/responses"
    raise RuntimeError("Super Brain Responses bridge is restricted to the local Codex endpoint or an exact explicit HTTPS direct endpoint.")


def _text_content(value: Any, *, role: str) -> list[dict[str, str]]:
    if isinstance(value, str):
        if not value.strip():
            raise RuntimeError(f"Responses bridge received empty {role} message content.")
        return [{"type": "input_text", "text": value}]
    if not isinstance(value, list):
        raise RuntimeError(f"Responses bridge received unsupported {role} message content.")

    content: list[dict[str, str]] = []
    for item in value:
        if not isinstance(item, dict):
            raise RuntimeError(f"Responses bridge received an invalid {role} content item.")
        item_type = item.get("type")
        if item_type == "text":
            text = item.get("text")
            if not isinstance(text, str) or not text.strip():
                raise RuntimeError(f"Responses bridge received empty {role} text.")
            content.append({"type": "input_text", "text": text})
            continue
        if item_type == "image_url":
            image = item.get("image_url")
            image_url = image.get("url") if isinstance(image, dict) else None
            if not isinstance(image_url, str) or not image_url.strip():
                raise RuntimeError(f"Responses bridge received an invalid {role} image.")
            content.append({"type": "input_image", "image_url": image_url})
            continue
        raise RuntimeError(f"Responses bridge does not support {role} content type {item_type!r}.")
    if not content:
        raise RuntimeError(f"Responses bridge received empty {role} content.")
    return content


def build_responses_payload(
    chat_request: dict[str, Any], *, reasoning_effort_override: str | None = None, stream: bool = True
) -> tuple[str, dict[str, Any]]:
    """Translate the official harness Chat request into a canonical Responses request."""

    model = chat_request.get("model")
    messages = chat_request.get("messages")
    if not isinstance(model, str) or not model.strip():
        raise RuntimeError("Responses bridge requires a requested model.")
    if not isinstance(messages, list) or not messages:
        raise RuntimeError("Responses bridge requires non-empty chat messages.")

    instructions: list[str] = []
    input_items: list[dict[str, Any]] = []
    for message in messages:
        if not isinstance(message, dict):
            raise RuntimeError("Responses bridge received an invalid chat message.")
        role = message.get("role")
        if not isinstance(role, str) or not role:
            raise RuntimeError("Responses bridge received a chat message without a role.")
        content = _text_content(message.get("content"), role=role)
        if role in {"system", "developer"}:
            if any(item["type"] != "input_text" for item in content):
                raise RuntimeError("Responses bridge does not support system images.")
            instructions.extend(item["text"] for item in content)
            continue
        if role not in {"user", "assistant"}:
            raise RuntimeError(f"Responses bridge does not support role {role!r}.")
        input_items.append({"type": "message", "role": role, "content": content})

    if not input_items:
        raise RuntimeError("Responses bridge requires at least one non-system message.")
    max_output_tokens = chat_request.get("max_tokens", chat_request.get("max_completion_tokens", 4096))
    try:
        max_output_tokens = int(max_output_tokens)
    except (TypeError, ValueError) as exc:
        raise RuntimeError("Responses bridge received an invalid output-token budget.") from exc
    if max_output_tokens <= 0:
        raise RuntimeError("Responses bridge requires a positive output-token budget.")

    payload: dict[str, Any] = {
        "model": model,
        "input": input_items,
        "max_output_tokens": max_output_tokens,
        "stream": bool(stream),
    }
    if instructions:
        payload["instructions"] = "\n\n".join(instructions)
    reasoning_effort = reasoning_effort_override or chat_request.get("reasoning_effort")
    if reasoning_effort is not None:
        payload["reasoning"] = {"effort": reasoning_effort}
    return model, payload


def _response_from_event_stream(raw: str) -> dict[str, Any]:
    completed: dict[str, Any] | None = None
    terminal_events: set[str] = set()
    for block in raw.replace("\r\n", "\n").split("\n\n"):
        event_name = ""
        data_lines: list[str] = []
        for line in block.split("\n"):
            if line.startswith("event:"):
                event_name = line[6:].strip()
            elif line.startswith("data:"):
                data_lines.append(line[5:].lstrip())
        if not data_lines:
            continue
        payload = "\n".join(data_lines).strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            value = json.loads(payload)
        except json.JSONDecodeError as exc:
            raise RuntimeError("Responses bridge received an invalid SSE event.") from exc
        if not isinstance(value, dict):
            continue
        event_type = value.get("type")
        if isinstance(event_type, str) and event_type in {
            "response.incomplete",
            "response.failed",
            "response.cancelled",
        }:
            terminal_events.add(event_type)
        response_value = value.get("response")
        if isinstance(response_value, dict):
            status = response_value.get("status")
            if isinstance(status, str) and status in {"incomplete", "failed", "cancelled"}:
                terminal_events.add("response.status=" + status)
        terminal_events.update(_terminal_response_diagnostics(value, response_value if isinstance(response_value, dict) else None))
        if event_name == "response.completed" or value.get("type") == "response.completed":
            candidate = value.get("response", value)
            if isinstance(candidate, dict):
                completed = candidate
    if completed is None:
        suffix = ""
        if terminal_events:
            suffix = " (terminal=" + ",".join(sorted(terminal_events)) + ")"
        raise RuntimeError("Responses bridge received no response.completed event." + suffix)
    if terminal_events:
        raise RuntimeError(
            "Responses bridge rejected response.completed after a terminal stream event."
            " (terminal=" + ",".join(sorted(terminal_events)) + ")"
        )
    return completed


def _response_text(response: dict[str, Any]) -> str:
    direct = response.get("output_text")
    if isinstance(direct, str) and direct.strip():
        return direct
    for output in response.get("output", []):
        if not isinstance(output, dict) or output.get("type") != "message":
            continue
        for content in output.get("content", []):
            if not isinstance(content, dict):
                continue
            value = content.get("text")
            if isinstance(value, str) and value.strip():
                return value
            if isinstance(value, dict) and isinstance(value.get("value"), str) and value["value"].strip():
                return value["value"]
    raise RuntimeError("Responses bridge received no text output.")


def responses_to_chat_response(raw: str, expected_model: str) -> SimpleNamespace:
    """Convert a final Responses reply into the limited Chat object the harness consumes."""

    stripped = raw.lstrip()
    if stripped.startswith("{"):
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise RuntimeError("Responses bridge received invalid JSON.") from exc
        response = value.get("response", value) if isinstance(value, dict) else None
    else:
        response = _response_from_event_stream(raw)
    if not isinstance(response, dict):
        raise RuntimeError("Responses bridge received an invalid final response.")
    model = response.get("model")
    response_id = response.get("id")
    if not isinstance(model, str) or not model.strip():
        raise RuntimeError("Responses bridge reply omitted its reported model.")
    if model != expected_model:
        raise RuntimeError(f"Responses bridge model mismatch: requested {expected_model}, received {model}.")
    if not isinstance(response_id, str) or not response_id.strip():
        raise RuntimeError("Responses bridge reply omitted its response id.")
    usage_value = response.get("usage")
    usage_value = usage_value if isinstance(usage_value, dict) else {}
    prompt_tokens = int(usage_value.get("prompt_tokens", usage_value.get("input_tokens", 0)) or 0)
    completion_tokens = int(usage_value.get("completion_tokens", usage_value.get("output_tokens", 0)) or 0)
    total_tokens = int(usage_value.get("total_tokens", prompt_tokens + completion_tokens) or 0)
    return SimpleNamespace(
        id=response_id,
        model=model,
        choices=[SimpleNamespace(message=SimpleNamespace(content=_response_text(response)))],
        usage=SimpleNamespace(
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            total_tokens=total_tokens,
        ),
    )


class _ResponsesSyncCompletions:
    def __init__(
        self,
        endpoint: str,
        api_key: str,
        reasoning_effort_override: str | None = None,
        stream: bool = True,
        max_retries: int = 0,
    ) -> None:
        self.endpoint = endpoint
        self.api_key = api_key
        self.reasoning_effort_override = reasoning_effort_override
        self.stream = bool(stream)
        self.max_retries = _bounded_retry_count(max_retries)

    def create(self, **chat_request: Any) -> SimpleNamespace:
        import httpx

        model, payload = build_responses_payload(
            chat_request, reasoning_effort_override=self.reasoning_effort_override, stream=self.stream
        )
        timeout = float(chat_request.get("timeout", 120))
        try:
            with httpx.Client(timeout=timeout, trust_env=False) as client:
                for attempt in range(self.max_retries + 1):
                    result = client.post(
                        self.endpoint,
                        json=payload,
                        headers={
                            "Authorization": f"Bearer {self.api_key}",
                            "Accept": "text/event-stream" if self.stream else "application/json",
                            "OpenAI-Beta": "responses=v1",
                        },
                    )
                    if result.is_success:
                        try:
                            return responses_to_chat_response(result.text, model)
                        except RuntimeError as exc:
                            terminal_code = _transient_terminal_error_code(exc)
                            if terminal_code and attempt < self.max_retries:
                                _retry_notice(f"terminal:{terminal_code}", attempt + 1, self.max_retries)
                                time.sleep(_retry_delay_seconds(attempt))
                                continue
                            raise
                    if result.status_code in _TRANSIENT_HTTP_STATUS_CODES and attempt < self.max_retries:
                        _retry_notice(result.status_code, attempt + 1, self.max_retries)
                        time.sleep(_retry_delay_seconds(attempt))
                        continue
                    summary = redact_http_error_summary(result.text)
                    raise RuntimeError(f"Responses bridge request failed with HTTP {result.status_code}: {summary}")
        except httpx.HTTPError as exc:
            raise RuntimeError("Responses bridge transport failed.") from exc
        raise RuntimeError("Responses bridge retry loop exited without a response.")


class _ResponsesAsyncCompletions:
    def __init__(
        self,
        endpoint: str,
        api_key: str,
        reasoning_effort_override: str | None = None,
        probe_first: bool = False,
        stream: bool = True,
        max_retries: int = 0,
    ) -> None:
        import httpx

        self.endpoint = endpoint
        self.api_key = api_key
        self.reasoning_effort_override = reasoning_effort_override
        self.probe_first = probe_first
        self.stream = bool(stream)
        self.max_retries = _bounded_retry_count(max_retries)
        self.probe_ready = not probe_first
        self.probe_failure: Exception | None = None
        self.probe_lock = asyncio.Lock()
        self.client = httpx.AsyncClient(trust_env=False)

    async def _post(self, model: str, payload: dict[str, Any], timeout: float) -> SimpleNamespace:
        import httpx

        for attempt in range(self.max_retries + 1):
            try:
                result = await self.client.post(
                    self.endpoint,
                    json=payload,
                    headers={
                        "Authorization": f"Bearer {self.api_key}",
                        "Accept": "text/event-stream" if self.stream else "application/json",
                        "OpenAI-Beta": "responses=v1",
                    },
                    timeout=timeout,
                )
            except httpx.HTTPError as exc:
                raise RuntimeError("Responses bridge transport failed.") from exc
            if result.is_success:
                try:
                    return responses_to_chat_response(result.text, model)
                except RuntimeError as exc:
                    terminal_code = _transient_terminal_error_code(exc)
                    if terminal_code and attempt < self.max_retries:
                        _retry_notice(f"terminal:{terminal_code}", attempt + 1, self.max_retries)
                        await asyncio.sleep(_retry_delay_seconds(attempt))
                        continue
                    raise
            if result.status_code in _TRANSIENT_HTTP_STATUS_CODES and attempt < self.max_retries:
                _retry_notice(result.status_code, attempt + 1, self.max_retries)
                await asyncio.sleep(_retry_delay_seconds(attempt))
                continue
            summary = redact_http_error_summary(result.text)
            raise RuntimeError(f"Responses bridge request failed with HTTP {result.status_code}: {summary}")
        raise RuntimeError("Responses bridge retry loop exited without a response.")

    async def create(self, **chat_request: Any) -> SimpleNamespace:
        model, payload = build_responses_payload(
            chat_request, reasoning_effort_override=self.reasoning_effort_override, stream=self.stream
        )
        timeout = float(chat_request.get("timeout", 120))
        if not self.probe_first or self.probe_ready:
            return await self._post(model, payload, timeout)

        async with self.probe_lock:
            if self.probe_failure is not None:
                raise RuntimeError("Responses bridge compatibility gate stopped remaining reader requests.") from self.probe_failure
            if not self.probe_ready:
                try:
                    response = await self._post(model, payload, timeout)
                except Exception as exc:
                    self.probe_failure = exc
                    raise
                self.probe_ready = True
                return response
        if self.probe_failure is not None:
            raise RuntimeError("Responses bridge compatibility gate stopped remaining reader requests.") from self.probe_failure
        return await self._post(model, payload, timeout)

    async def close(self) -> None:
        await self.client.aclose()


class _ResponsesSyncClient:
    def __init__(
        self,
        base_url: str | None,
        api_key: str,
        reasoning_effort_override: str | None = None,
        allowed_direct_base_url: str | None = None,
        stream: bool = True,
        max_retries: int = 0,
    ) -> None:
        self.chat = SimpleNamespace(
            completions=_ResponsesSyncCompletions(
                _responses_endpoint(base_url, allowed_direct_base_url=allowed_direct_base_url),
                api_key,
                reasoning_effort_override,
                stream,
                max_retries,
            )
        )


class _ResponsesAsyncClient:
    def __init__(
        self,
        base_url: str | None,
        api_key: str,
        reasoning_effort_override: str | None = None,
        probe_first: bool = False,
        allowed_direct_base_url: str | None = None,
        stream: bool = True,
        max_retries: int = 0,
    ) -> None:
        self.chat = SimpleNamespace(
            completions=_ResponsesAsyncCompletions(
                _responses_endpoint(base_url, allowed_direct_base_url=allowed_direct_base_url),
                api_key,
                reasoning_effort_override,
                probe_first,
                stream,
                max_retries,
            )
        )

    async def close(self) -> None:
        await self.chat.completions.close()


def install_super_brain_responses_bridge(
    harness_module: object,
    evaluator_module: object,
    *,
    reasoning_effort_override: str | None = None,
    probe_first: bool = False,
    allowed_direct_base_url: str | None = None,
    stream: bool = False,
    max_api_retries: int = 0,
) -> None:
    """Patch only the wrapper process so the official harness uses local Responses traffic."""

    def create_reader_client(base_url: str | None, api_key_env: str, api_key_file: str | None) -> _ResponsesAsyncClient:
        api_key = harness_module.load_api_key(api_key_env, api_key_file)
        if not isinstance(api_key, str) or not api_key.strip():
            raise RuntimeError("Responses bridge reader credential is missing.")
        return _ResponsesAsyncClient(
            base_url,
            api_key,
            reasoning_effort_override,
            probe_first,
            allowed_direct_base_url,
            stream,
            max_api_retries,
        )

    def create_evaluator_client(*, base_url: str | None, api_key: str | None) -> _ResponsesSyncClient:
        if not isinstance(api_key, str) or not api_key.strip():
            raise RuntimeError("Responses bridge evaluator credential is missing.")
        return _ResponsesSyncClient(
            base_url,
            api_key,
            reasoning_effort_override,
            allowed_direct_base_url,
            stream,
            max_api_retries,
        )

    harness_module.create_async_client = create_reader_client
    evaluator_module._create_openai_client = create_evaluator_client


def apply_super_brain_runtime_guards(
    harness_module: object,
    evaluator_module: object,
    *,
    max_api_retries: int,
    fail_fast: bool,
) -> None:
    """Apply wrapper-only budget guards without modifying the official clone."""

    harness_module.OPENAI_MAX_RETRIES = max_api_retries
    evaluator_module.OPENAI_MAX_RETRIES = max_api_retries
    if fail_fast:
        # The official harness otherwise converts BadRequestError into blank answers.
        class _FailFastBadRequestSentinel(Exception):
            pass

        harness_module.BadRequestError = _FailFastBadRequestSentinel


def install_super_brain_build_prompts_only_mode(harness_module: object) -> None:
    """Build sealed prompts without issuing reader or evaluator model calls."""

    async def build_only_reader_outputs(
        _args: object, prompt_rows: list[dict[str, Any]]
    ) -> dict[str, dict[str, Any]]:
        return {
            str(row["question_id"]): {
                "response_raw": "\\boxed{UNKNOWN}",
                "response_parsed_boxed": "UNKNOWN",
                "is_unknown": True,
                "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
            }
            for row in prompt_rows
        }

    def build_only_score_prediction(_row: dict[str, Any], _eval_config: dict[str, Any]) -> tuple[bool, str, bool]:
        return False, "build_prompts_only", True

    harness_module.generate_all_reader_outputs = build_only_reader_outputs
    harness_module.score_prediction = build_only_score_prediction


def install_super_brain_text_only_context_tokenizer(
    harness_module: object,
    *,
    tokenizer_loader: Callable[[], Any] | None = None,
) -> None:
    """Count text-only benchmark memory without loading a multimodal processor.

    The isolated Super Brain adapter deliberately omits trajectory screenshots,
    so this is valid only when every memory item is textual.  An image is an
    invariant violation rather than a reason to silently change tokenization.
    """

    tokenizer: Any | None = None

    def get_tokenizer() -> Any:
        nonlocal tokenizer
        if tokenizer is None:
            if tokenizer_loader is not None:
                tokenizer = tokenizer_loader()
            else:
                from transformers import AutoTokenizer

                tokenizer = AutoTokenizer.from_pretrained("Qwen/Qwen3.5-9B")
        return tokenizer

    def count_text_only_memory_context_tokens(
        memory_context: list[dict[str, Any]],
        loaded_images: list[Any | None],
    ) -> int:
        if len(memory_context) != len(loaded_images):
            raise RuntimeError("memory_context and loaded_images must have the same length")
        if not memory_context:
            return 0

        content_parts: list[dict[str, str]] = []
        for item, loaded_image in zip(memory_context, loaded_images):
            if not isinstance(item, dict) or item.get("type") != "text" or not isinstance(item.get("value"), str):
                raise RuntimeError("Text-only context tokenizer received a non-text benchmark memory item.")
            if loaded_image is not None:
                raise RuntimeError("Text-only context tokenizer received an unexpected benchmark image.")
            content_parts.append({"type": "text", "text": item["value"]})

        active_tokenizer = get_tokenizer()
        prompt_text = active_tokenizer.apply_chat_template(
            [{"role": "user", "content": content_parts}],
            tokenize=False,
            add_generation_prompt=False,
        )
        encoded = active_tokenizer(prompt_text, add_special_tokens=False)
        token_ids = encoded.get("input_ids") if isinstance(encoded, dict) else getattr(encoded, "input_ids", None)
        if hasattr(token_ids, "tolist"):
            token_ids = token_ids.tolist()
        if isinstance(token_ids, (list, tuple)) and token_ids and isinstance(token_ids[0], (list, tuple)):
            token_ids = token_ids[0]
        if not isinstance(token_ids, (list, tuple)):
            raise RuntimeError("Text-only context tokenizer returned an invalid input_ids payload.")
        return len(token_ids)

    harness_module.count_memory_context_tokens = count_text_only_memory_context_tokens


def _remaining_option_value(arguments: list[str], option: str) -> str | None:
    try:
        index = arguments.index(option)
    except ValueError:
        return None
    if index + 1 >= len(arguments):
        return None
    return arguments[index + 1]


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--lme-root", required=True)
    parser.add_argument("--super-brain-max-api-retries", type=int, default=0)
    parser.add_argument("--super-brain-fail-fast", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--super-brain-responses-bridge", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument(
        "--super-brain-responses-reasoning-effort",
        choices=("low", "medium", "high", "xhigh", "max"),
        default=None,
    )
    parser.add_argument("--super-brain-responses-probe-first", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--super-brain-responses-allowed-direct-base-url", default=None)
    parser.add_argument("--super-brain-responses-stream", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--super-brain-build-prompts-only", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--super-brain-text-only-context-tokenizer", action=argparse.BooleanOptionalAction, default=False)
    known, remaining = parser.parse_known_args()
    if remaining and remaining[0] == "--":
        remaining = remaining[1:]
    if "--save-memory" in remaining or "--load-memory-dir" in remaining:
        raise SystemExit("Super Brain LongMemEval-V2 runs do not support harness memory snapshots; use a fresh isolated run root.")

    lme_root = Path(known.lme_root).expanduser().resolve()
    if not (lme_root / "evaluation" / "harness.py").is_file():
        raise SystemExit("--lme-root must point to the official LongMemEval-V2 repository.")
    if known.super_brain_max_api_retries < 0:
        raise SystemExit("--super-brain-max-api-retries must be zero or greater.")
    if (
        (
            known.super_brain_responses_reasoning_effort
            or known.super_brain_responses_probe_first
            or known.super_brain_responses_allowed_direct_base_url
        )
        and not known.super_brain_responses_bridge
    ):
        raise SystemExit("Responses bridge options require --super-brain-responses-bridge.")
    package_runtime = Path(__file__).resolve().parent
    if str(lme_root) not in sys.path:
        sys.path.insert(0, str(lme_root))
    if str(package_runtime) not in sys.path:
        sys.path.insert(0, str(package_runtime))

    from longmemeval_v2_adapter import register_lme_v2_memory

    register_lme_v2_memory()
    from evaluation import harness as harness_module
    from evaluation import qa_eval_metrics

    # The wrapper owns the external-request budget; the pinned harness stays unchanged.
    apply_super_brain_runtime_guards(
        harness_module,
        qa_eval_metrics,
        max_api_retries=known.super_brain_max_api_retries,
        fail_fast=known.super_brain_fail_fast,
    )
    if known.super_brain_text_only_context_tokenizer:
        install_super_brain_text_only_context_tokenizer(harness_module)
    if known.super_brain_build_prompts_only:
        install_super_brain_build_prompts_only_mode(harness_module)
    if known.super_brain_responses_bridge:
        install_super_brain_responses_bridge(
            harness_module,
            qa_eval_metrics,
            reasoning_effort_override=known.super_brain_responses_reasoning_effort,
            probe_first=known.super_brain_responses_probe_first,
            allowed_direct_base_url=known.super_brain_responses_allowed_direct_base_url,
            stream=known.super_brain_responses_stream,
            max_api_retries=known.super_brain_max_api_retries,
        )

    sys.argv = [str(lme_root / "evaluation" / "harness.py"), *remaining]
    result = harness_module.main()
    if known.super_brain_build_prompts_only:
        output_dir = _remaining_option_value(remaining, "--output-dir")
        if output_dir:
            receipt = {
                "schema": "super-brain.longmemeval-v2-build-prompts-only.v1",
                "status": "completed_non_publishable",
                "readerModelCalls": 0,
                "evaluatorModelCalls": 0,
                "officialScoreClaimed": False,
                "textOnlyContextTokenizer": bool(known.super_brain_text_only_context_tokenizer),
            }
            Path(output_dir).joinpath("super-brain-build-prompts-only.json").write_text(
                json.dumps(receipt, ensure_ascii=True) + "\n", encoding="utf-8"
            )
    return int(result) if isinstance(result, int) else 0


if __name__ == "__main__":
    raise SystemExit(main())
