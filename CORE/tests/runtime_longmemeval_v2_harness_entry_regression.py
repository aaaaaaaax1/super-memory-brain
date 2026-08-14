"""Regression coverage for the LongMemEval-V2 wrapper's no-retry budget gate."""

from __future__ import annotations

import importlib.util
import asyncio
import json
import os
import sys
import tempfile
import threading
import types
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENTRY_PATH = ROOT / "runtime" / "longmemeval_v2_harness_entry.py"


def load_entry_module():
    spec = importlib.util.spec_from_file_location("lme_v2_entry_regression", ENTRY_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> None:
    entry = load_entry_module()
    model, payload = entry.build_responses_payload(
        {
            "model": "gpt-5.6-terra",
            "messages": [
                {"role": "system", "content": "Use only retained evidence."},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "What changed?"},
                        {"type": "image_url", "image_url": {"url": "data:image/png;base64,AA=="}},
                    ],
                },
            ],
            "max_tokens": 321,
            "reasoning_effort": "high",
        }
    )
    assert model == "gpt-5.6-terra"
    assert payload["instructions"] == "Use only retained evidence."
    assert payload["input"][0]["content"][0] == {"type": "input_text", "text": "What changed?"}
    assert payload["input"][0]["content"][1] == {"type": "input_image", "image_url": "data:image/png;base64,AA=="}
    assert payload["reasoning"] == {"effort": "high"}
    assert entry.redact_http_error_summary("<!DOCTYPE html><html><body>proxy failure</body></html>") == "upstream returned non-JSON HTML error"
    redacted_json_error = entry.redact_http_error_summary(
        json.dumps(
            {
                "error": {
                    "code": "invalid_parameter",
                    "type": "invalid_request_error",
                    "param": "reasoning.effort",
                    "message": "Echoed prompt or answer content must never enter a diagnostic.",
                }
            }
        )
    )
    assert redacted_json_error == "code=invalid_parameter; type=invalid_request_error; param=reasoning.effort"
    assert "Echoed prompt" not in redacted_json_error
    assert 524 in entry._TRANSIENT_HTTP_STATUS_CODES
    _, buffered_payload = entry.build_responses_payload(
        {
            "model": "gpt-5.6-terra",
            "messages": [{"role": "user", "content": "Use buffered Responses."}],
            "max_tokens": 64,
        },
        stream=False,
    )
    assert buffered_payload["stream"] is False
    _, override_payload = entry.build_responses_payload(
        {
            "model": "gpt-5.6-terra",
            "messages": [{"role": "user", "content": "Use the verified route."}],
            "max_tokens": 64,
            "reasoning_effort": "high",
        },
        reasoning_effort_override="max",
    )
    assert override_payload["reasoning"] == {"effort": "max"}
    assert entry._responses_endpoint("http://127.0.0.1:18883/codex/v1") == "http://127.0.0.1:18883/codex/v1/responses"
    try:
        entry._responses_endpoint("https://api-coding.com/v1")
    except RuntimeError as exc:
        assert "restricted" in str(exc)
    else:  # pragma: no cover - direct endpoints require an exact explicit binding.
        raise AssertionError("Responses bridge accepted an unbound direct endpoint")
    assert (
        entry._responses_endpoint(
            "https://api-coding.com/v1",
            allowed_direct_base_url="https://api-coding.com/v1",
        )
        == "https://api-coding.com/v1/responses"
    )
    try:
        entry._responses_endpoint(
            "https://api-coding.com/v1",
            allowed_direct_base_url="https://other.example/v1",
        )
    except RuntimeError as exc:
        assert "restricted" in str(exc)
    else:  # pragma: no cover - the direct binding must be exact.
        raise AssertionError("Responses bridge accepted a mismatched direct endpoint")

    build_only_harness = types.SimpleNamespace()
    entry.install_super_brain_build_prompts_only_mode(build_only_harness)
    build_only_outputs = asyncio.run(
        build_only_harness.generate_all_reader_outputs(
            object(), [{"question_id": "case-1"}, {"question_id": "case-2"}]
        )
    )
    assert set(build_only_outputs) == {"case-1", "case-2"}
    assert build_only_outputs["case-1"]["response_parsed_boxed"] == "UNKNOWN"
    assert build_only_harness.score_prediction({}, {}) == (False, "build_prompts_only", True)

    class FakeTokenizer:
        def apply_chat_template(self, messages, *, tokenize, add_generation_prompt):
            assert tokenize is False
            assert add_generation_prompt is False
            assert messages == [{"role": "user", "content": [{"type": "text", "text": "retained evidence"}]}]
            return "rendered benchmark prompt"

        def __call__(self, text, *, add_special_tokens):
            assert text == "rendered benchmark prompt"
            assert add_special_tokens is False
            return {"input_ids": [10, 20, 30, 40]}

    tokenizer_harness = types.SimpleNamespace()
    entry.install_super_brain_text_only_context_tokenizer(tokenizer_harness, tokenizer_loader=FakeTokenizer)
    assert tokenizer_harness.count_memory_context_tokens(
        [{"type": "text", "value": "retained evidence"}],
        [None],
    ) == 4
    try:
        tokenizer_harness.count_memory_context_tokens(
            [{"type": "image", "value": "unexpected.png"}],
            [object()],
        )
    except RuntimeError as exc:
        assert "non-text" in str(exc)
    else:  # pragma: no cover - the text-only adapter must reject images.
        raise AssertionError("Text-only context tokenizer accepted an image memory item")

    completed = entry.responses_to_chat_response(
        'event: response.completed\n'
        'data: {"type":"response.completed","response":{"id":"resp_1","model":"gpt-5.6-terra","output_text":"\\\\boxed{ok}","usage":{"input_tokens":11,"output_tokens":7}}}\n\n',
        "gpt-5.6-terra",
    )
    assert completed.choices[0].message.content == "\\boxed{ok}"
    assert completed.usage.prompt_tokens == 11
    assert completed.usage.completion_tokens == 7
    try:
        entry.responses_to_chat_response(
            '{"id":"resp_2","model":"different-model","output_text":"x"}',
            "gpt-5.6-terra",
        )
    except RuntimeError as exc:
        assert "model mismatch" in str(exc)
    else:  # pragma: no cover - identity mismatch must fail closed.
        raise AssertionError("Responses bridge accepted a reported-model mismatch")
    try:
        entry.responses_to_chat_response(
            'event: response.incomplete\n'
            'data: {"type":"response.incomplete","response":{"status":"incomplete"}}\n\n',
            "gpt-5.6-terra",
        )
    except RuntimeError as exc:
        assert "response.incomplete" in str(exc)
        assert "response.status=incomplete" in str(exc)
    else:  # pragma: no cover - incomplete streams must remain a hard failure.
        raise AssertionError("Responses bridge accepted an incomplete stream")
    try:
        entry.responses_to_chat_response(
            'event: response.incomplete\n'
            'data: {"type":"response.incomplete","response":{"status":"incomplete"}}\n\n'
            'event: response.completed\n'
            'data: {"type":"response.completed","response":{"id":"resp_after_terminal","model":"gpt-5.6-terra","output_text":"\\\\boxed{unsafe}"}}\n\n',
            "gpt-5.6-terra",
        )
    except RuntimeError as exc:
        message = str(exc)
        assert "rejected response.completed" in message
        assert "response.incomplete" in message
        assert "response.status=incomplete" in message
    else:  # pragma: no cover - any terminal event must poison the stream.
        raise AssertionError("Responses bridge accepted response.completed after an incomplete stream")
    try:
        entry.responses_to_chat_response(
            'event: response.failed\n'
            'data: {"type":"response.failed","response":{"status":"failed","error":{"type":"invalid_request_error","code":"unsupported_parameter","param":"reasoning.effort","message":"secret token=sk-live-1234567890"}}}\n\n',
            "gpt-5.6-terra",
        )
    except RuntimeError as exc:
        message = str(exc)
        assert "response.failed" in message
        assert "response.status=failed" in message
        assert "error.type=invalid_request_error" in message
        assert "error.code=unsupported_parameter" in message
        assert "error.param=reasoning.effort" in message
        assert "secret token" not in message
        assert "sk-live-1234567890" not in message
    else:  # pragma: no cover - failed streams must expose only safe diagnostics.
        raise AssertionError("Responses bridge accepted a failed stream")

    class ResponsesHandler(BaseHTTPRequestHandler):
        calls: list[dict] = []
        retry_attempts = 0
        terminal_retry_attempts = 0

        def do_POST(self) -> None:  # noqa: N802 - stdlib handler signature.
            length = int(self.headers["Content-Length"])
            body = json.loads(self.rfile.read(length).decode("utf-8"))
            self.__class__.calls.append(
                {
                    "path": self.path,
                    "authorization": self.headers.get("Authorization"),
                    "accept": self.headers.get("Accept"),
                    "openai_beta": self.headers.get("OpenAI-Beta"),
                    "body": body,
                }
            )
            if body["model"] == "rejected-model":
                encoded = json.dumps(
                    {
                        "error": {
                            "code": "invalid_parameter",
                            "type": "invalid_request_error",
                            "param": "reasoning.effort",
                            "message": "Unsupported parameter reasoning.effort; token=sk-live-1234567890",
                        }
                    }
                ).encode("utf-8")
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
                return
            if body["model"] == "retry-model":
                self.__class__.retry_attempts += 1
                if self.__class__.retry_attempts == 1:
                    encoded = b"<!DOCTYPE html><html><body>temporary proxy failure</body></html>"
                    self.send_response(502)
                    self.send_header("Content-Type", "text/html")
                    self.send_header("Content-Length", str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)
                    return
            if body["model"] == "terminal-retry-model":
                self.__class__.terminal_retry_attempts += 1
                if self.__class__.terminal_retry_attempts == 1:
                    failed = {
                        "type": "response.failed",
                        "response": {
                            "status": "failed",
                            "error": {"code": "rate_limit_exceeded", "message": "do not expose this"},
                        },
                    }
                    encoded = ("event: response.failed\ndata: " + json.dumps(failed) + "\n\n").encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)
                    return
            response = {
                "type": "response.completed",
                "response": {
                    "id": f"resp_{len(self.__class__.calls)}",
                    "model": body["model"],
                    "output_text": "\\boxed{bridge}",
                    "usage": {"input_tokens": 5, "output_tokens": 3},
                },
            }
            encoded = ("event: response.completed\ndata: " + json.dumps(response) + "\n\n").encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, _format: str, *_args: object) -> None:
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), ResponsesHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base_url = f"http://127.0.0.1:{server.server_port}/codex/v1"
        sync_client = entry._ResponsesSyncClient(base_url, "test-key", "max")
        sync_response = sync_client.chat.completions.create(
            model="gpt-5.6-terra",
            messages=[{"role": "user", "content": "sync"}],
            max_tokens=64,
            timeout=5,
        )
        assert sync_response.choices[0].message.content == "\\boxed{bridge}"
        try:
            sync_client.chat.completions.create(
                model="rejected-model",
                messages=[{"role": "user", "content": "rejection"}],
                max_tokens=64,
                timeout=5,
            )
        except RuntimeError as exc:
            message = str(exc)
            assert "HTTP 400" in message
            assert "param=reasoning.effort" in message
            assert "Unsupported parameter" not in message
            assert "token=" not in message
            assert "sk-live-1234567890" not in message
        else:  # pragma: no cover - non-success HTTP responses must fail closed.
            raise AssertionError("Responses bridge accepted an HTTP 400 response")

        async def run_async() -> None:
            async_client = entry._ResponsesAsyncClient(base_url, "test-key", stream=False)
            try:
                async_response = await async_client.chat.completions.create(
                    model="gpt-5.6-terra",
                    messages=[{"role": "user", "content": "async"}],
                    max_tokens=64,
                    timeout=5,
                )
                assert async_response.choices[0].message.content == "\\boxed{bridge}"
            finally:
                await async_client.close()

        asyncio.run(run_async())

        async def run_async_retry() -> None:
            async_client = entry._ResponsesAsyncClient(base_url, "test-key", "max", stream=False, max_retries=1)
            try:
                async_response = await async_client.chat.completions.create(
                    model="retry-model",
                    messages=[{"role": "user", "content": "retry"}],
                    max_tokens=64,
                    timeout=5,
                )
                assert async_response.choices[0].message.content == "\\boxed{bridge}"
            finally:
                await async_client.close()

        asyncio.run(run_async_retry())
        assert ResponsesHandler.retry_attempts == 2

        async def run_async_terminal_retry() -> None:
            async_client = entry._ResponsesAsyncClient(base_url, "test-key", "max", stream=False, max_retries=1)
            try:
                async_response = await async_client.chat.completions.create(
                    model="terminal-retry-model",
                    messages=[{"role": "user", "content": "terminal retry"}],
                    max_tokens=64,
                    timeout=5,
                )
                assert async_response.choices[0].message.content == "\\boxed{bridge}"
            finally:
                await async_client.close()

        asyncio.run(run_async_terminal_retry())
        assert ResponsesHandler.terminal_retry_attempts == 2

        async def run_probe_gate() -> None:
            async_client = entry._ResponsesAsyncClient(base_url, "test-key", "max", probe_first=True)
            call_count_before = len(ResponsesHandler.calls)
            try:
                results = await asyncio.gather(
                    *[
                        async_client.chat.completions.create(
                            model="rejected-model",
                            messages=[{"role": "user", "content": "gate"}],
                            max_tokens=64,
                            timeout=5,
                        )
                        for _ in range(3)
                    ],
                    return_exceptions=True,
                )
                assert all(isinstance(result, RuntimeError) for result in results)
                assert len(ResponsesHandler.calls) == call_count_before + 1
            finally:
                await async_client.close()

        asyncio.run(run_probe_gate())
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()
    assert len(ResponsesHandler.calls) == 8
    assert all(call["path"] == "/codex/v1/responses" for call in ResponsesHandler.calls)
    assert all(call["authorization"] == "Bearer test-key" for call in ResponsesHandler.calls)
    assert all(call["openai_beta"] == "responses=v1" for call in ResponsesHandler.calls)
    assert all(call["body"]["input"][0]["content"][0]["type"] == "input_text" for call in ResponsesHandler.calls)
    assert ResponsesHandler.calls[0]["body"]["reasoning"] == {"effort": "max"}
    assert ResponsesHandler.calls[2]["body"]["stream"] is False
    assert ResponsesHandler.calls[2]["accept"] == "application/json"

    class OriginalBadRequest(Exception):
        pass

    guard_harness = types.SimpleNamespace(
        OPENAI_MAX_RETRIES=10,
        BadRequestError=OriginalBadRequest,
    )
    guard_evaluator = types.SimpleNamespace(OPENAI_MAX_RETRIES=10)
    entry.apply_super_brain_runtime_guards(
        guard_harness,
        guard_evaluator,
        max_api_retries=0,
        fail_fast=True,
    )
    assert guard_harness.OPENAI_MAX_RETRIES == 0
    assert guard_evaluator.OPENAI_MAX_RETRIES == 0

    bridge_harness = types.SimpleNamespace(load_api_key=lambda _env, _file: "test-key")
    bridge_evaluator = types.SimpleNamespace()
    entry.install_super_brain_responses_bridge(
        bridge_harness,
        bridge_evaluator,
        max_api_retries=2,
    )
    retry_reader = bridge_harness.create_async_client("http://127.0.0.1:18883/codex/v1", "TEST_KEY", None)
    retry_evaluator = bridge_evaluator._create_openai_client(
        base_url="http://127.0.0.1:18883/codex/v1",
        api_key="test-key",
    )
    assert retry_reader.chat.completions.max_retries == 2
    assert retry_evaluator.chat.completions.max_retries == 2
    asyncio.run(retry_reader.close())
    try:
        raise OriginalBadRequest()
    except guard_harness.BadRequestError as exc:  # pragma: no cover - must not match.
        raise AssertionError("Original BadRequestError remained silently catchable") from exc
    except OriginalBadRequest:
        pass

    with tempfile.TemporaryDirectory() as directory:
        lme_root = Path(directory) / "official"
        evaluation = lme_root / "evaluation"
        evaluation.mkdir(parents=True)
        (evaluation / "__init__.py").write_text("", encoding="utf-8")
        (evaluation / "qa_eval_metrics.py").write_text("OPENAI_MAX_RETRIES = 10\n", encoding="utf-8")
        receipt_path = Path(directory) / "receipt.json"
        (evaluation / "harness.py").write_text(
            "import json, os\n"
            "OPENAI_MAX_RETRIES = 10\n"
            "def main():\n"
            "    from evaluation import qa_eval_metrics\n"
            "    with open(os.environ['LME_V2_RETRY_RECEIPT'], 'w', encoding='utf-8') as handle:\n"
            "        json.dump({'harness': OPENAI_MAX_RETRIES, 'evaluator': qa_eval_metrics.OPENAI_MAX_RETRIES}, handle)\n"
            "    return 0\n",
            encoding="utf-8",
        )

        fake_adapter = types.ModuleType("longmemeval_v2_adapter")
        fake_adapter.register_lme_v2_memory = lambda: None
        prior_adapter = sys.modules.get("longmemeval_v2_adapter")
        prior_argv = sys.argv
        prior_receipt = os.environ.get("LME_V2_RETRY_RECEIPT")
        try:
            sys.modules["longmemeval_v2_adapter"] = fake_adapter
            os.environ["LME_V2_RETRY_RECEIPT"] = str(receipt_path)
            sys.argv = [
                str(ENTRY_PATH),
                "--lme-root",
                str(lme_root),
                "--super-brain-max-api-retries",
                "0",
            ]
            assert entry.main() == 0
        finally:
            sys.argv = prior_argv
            if prior_receipt is None:
                os.environ.pop("LME_V2_RETRY_RECEIPT", None)
            else:
                os.environ["LME_V2_RETRY_RECEIPT"] = prior_receipt
            if prior_adapter is None:
                sys.modules.pop("longmemeval_v2_adapter", None)
            else:
                sys.modules["longmemeval_v2_adapter"] = prior_adapter
            for name in ("evaluation.harness", "evaluation.qa_eval_metrics", "evaluation"):
                sys.modules.pop(name, None)

        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        assert receipt == {"harness": 0, "evaluator": 0}, receipt

    print("runtime_longmemeval_v2_harness_entry_regression: PASS")


if __name__ == "__main__":
    main()
