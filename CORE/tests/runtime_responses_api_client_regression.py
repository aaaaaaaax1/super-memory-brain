from __future__ import annotations

import io
import json
import os
import sys
import tempfile
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "runtime"))
import responses_api_client as client  # noqa: E402


def expect_value_error(callable_value, expected: str) -> None:
    try:
        callable_value()
    except ValueError as exc:
        assert str(exc) == expected, exc
    else:
        raise AssertionError(f"expected {expected}")


def test_codex_config_resolution() -> None:
    with tempfile.TemporaryDirectory() as directory:
        config_path = Path(directory) / "config.toml"
        config_path.write_text(
            '\n'.join(
                (
                    'model_provider = "custom"',
                    '[model_providers.custom]',
                    'base_url = "http://127.0.0.1:18883/v1"',
                    'experimental_bearer_token = "test-bearer-token"',
                    'wire_api = "responses"',
                )
            ),
            encoding="utf-8",
        )
        resolved = client.resolve_codex_desktop_connection(str(config_path))
        assert resolved["ok"] is True
        assert resolved["responsesUrl"] == "http://127.0.0.1:18883/v1/responses"
        assert resolved["apiKey"] == "test-bearer-token"

        config_path.write_text(
            config_path.read_text(encoding="utf-8").replace('wire_api = "responses"', 'wire_api = "chat_completions"'),
            encoding="utf-8",
        )
        rejected = client.resolve_codex_desktop_connection(str(config_path))
        assert rejected == {"ok": False, "code": "CODEX_PROVIDER_WIRE_API_UNSUPPORTED"}


def test_html_rejection_and_sse_completion() -> None:
    expect_value_error(lambda: client.parse_response_body("<!doctype html><html>bad</html>", "text/html"), "RESPONSES_HTML_REJECTED")
    response = client.parse_response_body(
        'event: response.completed\n'
        'data: {"type":"response.completed","response":{"id":"resp-test","model":"gpt-test","output_text":"ok"}}\n\n',
        "text/event-stream",
    )
    assert response["id"] == "resp-test"
    assert response["model"] == "gpt-test"

    class Reader:
        def __init__(self) -> None:
            self.lines = iter(
                (
                    b'event: response.completed\n',
                    b'data: {"type":"response.completed","response":{"id":"reader-test","model":"gpt-test","output_text":"ok"}}\n',
                    b'\n',
                    b'this tail must not be read\n',
                )
            )

        def readline(self) -> bytes:
            return next(self.lines)

    streamed = client.response_from_stream_reader(Reader())
    assert streamed["id"] == "reader-test"


def test_local_codex_request_metadata_is_isolated() -> None:
    endpoint = "http://127.0.0.1:18883/codex/v1/responses"
    headers = client.request_headers(endpoint, "test-bearer-token")
    metadata = json.loads(headers["x-codex-turn-metadata"])
    # The local Atoapi Codex route follows Codex Desktop's native streaming
    # contract; the client still accepts a terminal JSON reply defensively.
    assert headers["Accept"] == "text/event-stream"
    assert headers["OpenAI-Beta"] == "responses=v1"
    assert metadata["request_kind"] == "turn"
    assert metadata["session_id"] == metadata["thread_id"]
    assert metadata["session_id"].startswith("super-brain-eval-")
    remote_headers = client.request_headers(
        "http://127.0.0.1:18883/v1/responses", "test-bearer-token"
    )
    assert "x-codex-turn-metadata" not in remote_headers
    assert remote_headers["Accept"] == "text/event-stream, application/json"


def test_main_has_one_transport_attempt() -> None:
    original_request_once = client.request_once
    original_stdin = sys.stdin
    original_argv = sys.argv
    original_environment = {name: os.environ.get(name) for name in ("SUPER_BRAIN_RESPONSE_CLIENT_ENDPOINT", "SUPER_BRAIN_RESPONSE_CLIENT_API_KEY", "SUPER_BRAIN_RESPONSE_CLIENT_TIMEOUT_SECONDS")}
    calls = 0

    def fail_once(*args, **kwargs):
        nonlocal calls
        calls += 1
        raise OSError("network unavailable")

    client.request_once = fail_once
    sys.stdin = io.StringIO('{"model":"gpt-test","input":"probe"}\n')
    sys.argv = ["responses_api_client.py"]
    os.environ["SUPER_BRAIN_RESPONSE_CLIENT_ENDPOINT"] = "http://127.0.0.1:18883/v1/responses"
    os.environ["SUPER_BRAIN_RESPONSE_CLIENT_API_KEY"] = "test-bearer-token"
    os.environ["SUPER_BRAIN_RESPONSE_CLIENT_TIMEOUT_SECONDS"] = "10"
    try:
        with redirect_stdout(io.StringIO()):
            assert client.main() == 1
        assert calls == 1
    finally:
        client.request_once = original_request_once
        sys.stdin = original_stdin
        sys.argv = original_argv
        for name, value in original_environment.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


def test_stdin_envelope_has_one_transport_attempt() -> None:
    original_request_once = client.request_once
    original_stdin = sys.stdin
    original_argv = sys.argv
    calls: list[tuple[str, str, dict[object, object], bool, int]] = []

    def fail_once(endpoint, api_key, payload, direct, timeout):
        calls.append((endpoint, api_key, payload, direct, timeout))
        raise OSError("network unavailable")

    client.request_once = fail_once
    sys.stdin = io.StringIO(
        json.dumps(
            {
                "endpoint": "http://127.0.0.1:18883/v1/responses",
                "apiKey": "envelope-bearer-token",
                "timeoutSeconds": 10,
                "payload": {"model": "gpt-test", "input": "probe"},
            }
        )
        + "\n"
    )
    sys.argv = ["responses_api_client.py", "--stdin-envelope"]
    try:
        with redirect_stdout(io.StringIO()):
            assert client.main() == 1
        assert len(calls) == 1
        endpoint, api_key, payload, direct, timeout = calls[0]
        assert endpoint == "http://127.0.0.1:18883/v1/responses"
        assert api_key == "envelope-bearer-token"
        assert payload == {"model": "gpt-test", "input": "probe"}
        assert direct is True
        assert timeout == 10
    finally:
        client.request_once = original_request_once
        sys.stdin = original_stdin
        sys.argv = original_argv


def test_stdin_envelope_decodes_utf8_bytes() -> None:
    original_request_once = client.request_once
    original_stdin = sys.stdin
    original_argv = sys.argv
    calls: list[tuple[str, str, dict[object, object], bool, int]] = []

    class BinaryStdin:
        def __init__(self, value: bytes) -> None:
            self.buffer = io.BytesIO(value)

    def fail_once(endpoint, api_key, payload, direct, timeout):
        calls.append((endpoint, api_key, payload, direct, timeout))
        raise OSError("network unavailable")

    envelope = {
        "endpoint": "http://127.0.0.1:18883/v1/responses",
        "apiKey": "envelope-bearer-token",
        "timeoutSeconds": 10,
        "payload": {"model": "gpt-test", "input": "中文传输校验"},
    }
    client.request_once = fail_once
    sys.stdin = BinaryStdin((json.dumps(envelope, ensure_ascii=False) + "\n").encode("utf-8"))
    sys.argv = ["responses_api_client.py", "--stdin-envelope"]
    try:
        with redirect_stdout(io.StringIO()):
            assert client.main() == 1
        assert len(calls) == 1
        assert calls[0][2] == envelope["payload"]
    finally:
        client.request_once = original_request_once
        sys.stdin = original_stdin
        sys.argv = original_argv


def main() -> None:
    test_codex_config_resolution()
    test_html_rejection_and_sse_completion()
    test_local_codex_request_metadata_is_isolated()
    test_main_has_one_transport_attempt()
    test_stdin_envelope_has_one_transport_attempt()
    test_stdin_envelope_decodes_utf8_bytes()
    print("runtime_responses_api_client_regression: PASS")


if __name__ == "__main__":
    main()
