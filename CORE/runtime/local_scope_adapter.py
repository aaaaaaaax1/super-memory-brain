"""Host-neutral local MCP embedding adapter.

This module is the package-owned launch seam for a real local Super Brain
scope.  It deliberately owns only process construction facts:

* the real project ``cwd``;
* one strict, random ``SUPER_BRAIN_LOCAL_SESSION_ID``; and
* a bounded launcher environment.

Contract, workline, task, channel, pairing, and Broker ownership remain H7
runtime responsibilities.  They are intentionally absent from this API so a
host cannot turn a launch request into a scope selector.  A scope change
requires a fresh launcher process; callers must not mutate a live process's
environment or try to rebind it through MCP arguments.
"""

from __future__ import annotations

import os
import re
import secrets
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from types import MappingProxyType
from typing import Any, Mapping


LOCAL_SESSION_ENV = "SUPER_BRAIN_LOCAL_SESSION_ID"
ADAPTER_SCHEMA = "super-brain.local-mcp-adapter.v1"
SESSION_PATTERN = r"^sid-[a-f0-9]{16,64}$"
SESSION_RE = re.compile(SESSION_PATTERN, re.IGNORECASE)

# Only ordinary interpreter/OS values cross from an embedding host into the
# launcher.  In particular, do not relay Host/Codex identifiers, context
# snapshots, task selectors, package overrides, or state-root overrides.
WORKER_ENV_KEYS = (
    "APPDATA",
    "COMSPEC",
    "ComSpec",
    "HOME",
    "LANG",
    "LC_ALL",
    "LOCALAPPDATA",
    "OS",
    "PATH",
    "PATHEXT",
    "PROCESSOR_ARCHITECTURE",
    "PROGRAMDATA",
    "PYTHONIOENCODING",
    "PYTHONUTF8",
    "SystemRoot",
    "SYSTEMROOT",
    "TEMP",
    "TMP",
    "USERPROFILE",
    "WINDIR",
)


class LocalScopeAdapterError(ValueError):
    """A deterministic input error raised before a process is started."""

    def __init__(self, code: str) -> None:
        self.code = str(code)
        super().__init__(self.code)


def validate_session_id(value: Any) -> str | None:
    """Return a normalized strict local session id, or ``None``.

    The adapter never hashes or otherwise repairs an invalid value.  Legacy
    CLI compatibility may retain its own historical normalization, but this
    host-neutral launch contract is intentionally strict.
    """

    text = str(value or "").strip().lower()
    return text if SESSION_RE.fullmatch(text) else None


def generate_session_id() -> str:
    """Generate a cryptographically random local session id."""

    return "sid-" + secrets.token_hex(24)


# Friendly alias for embedding hosts that prefer the shorter name.
new_session_id = generate_session_id


def _normalized_directory(value: str | Path | None, *, invalid_code: str) -> Path:
    if value is None or not str(value).strip():
        raise LocalScopeAdapterError(invalid_code)
    try:
        candidate = Path(value).expanduser().resolve()
    except (OSError, RuntimeError, TypeError, ValueError):
        raise LocalScopeAdapterError(invalid_code) from None
    if not candidate.is_dir():
        raise LocalScopeAdapterError(invalid_code)
    return candidate


def build_environment(
    session_id: str,
    *,
    source: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Build the bounded launcher environment for one local process.

    The returned mapping contains the SID because it is the launch contract's
    private process input.  It must never be serialized into MCP requests,
    logs, or user-visible output.  Host-specific values in ``source`` are
    ignored, not copied and then scrubbed later.
    """

    normalized = validate_session_id(session_id)
    if normalized is None:
        raise LocalScopeAdapterError("H7_SCOPE_INJECTION_LOCAL_SESSION_REQUIRED")
    inherited: Mapping[str, str] = os.environ if source is None else source
    environment: dict[str, str] = {}
    for name in WORKER_ENV_KEYS:
        value = inherited.get(name)
        if isinstance(value, str) and value:
            environment[name] = value
    environment[LOCAL_SESSION_ENV] = normalized
    return environment


@dataclass(frozen=True, slots=True)
class LocalMcpLaunchSpec:
    """Immutable process launch description for one cwd/SID scope.

    ``environment`` is marked ``repr=False`` so an accidental diagnostic or
    exception repr cannot disclose the private SID.  The host still receives
    it as a normal mapping for ``subprocess.Popen``.
    """

    executable: str
    arguments: tuple[str, ...]
    cwd: Path
    environment: Mapping[str, str] = field(repr=False)
    schema: str = ADAPTER_SCHEMA
    requires_fresh_process: bool = True

    def __post_init__(self) -> None:
        # Keep the launch contract immutable even when a caller supplied a
        # mutable dict.  ``repr=False`` above prevents the private SID from
        # appearing in ordinary diagnostics.
        object.__setattr__(self, "environment", MappingProxyType(dict(self.environment)))

    @property
    def argv(self) -> tuple[str, ...]:
        """Return the complete argv; it intentionally contains no SID."""

        return (self.executable, *self.arguments)

    @property
    def requiresFreshProcess(self) -> bool:  # noqa: N802 - host JSON spelling
        """Camel-case compatibility spelling for non-Python hosts."""

        return self.requires_fresh_process


def build_launch_spec(
    package_root: str | Path,
    memory_root: str | Path,
    workspace_root: str | Path,
    session_id: str,
    *,
    python_executable: str | Path | None = None,
    environment_source: Mapping[str, str] | None = None,
) -> LocalMcpLaunchSpec:
    """Build the only supported host-neutral local MCP launch contract.

    No task/workline/contract/channel/ref selector is accepted.  ``cwd`` is
    the normalized workspace root and the SID appears only in the bounded
    environment.  A caller must create a new process for every scope change.
    """

    normalized_session = validate_session_id(session_id)
    if normalized_session is None:
        raise LocalScopeAdapterError("H7_SCOPE_INJECTION_LOCAL_SESSION_REQUIRED")

    package = _normalized_directory(package_root, invalid_code="H7_LOCAL_MCP_LAUNCHER_PACKAGE_INVALID")
    launcher = package / "runtime" / "local_mcp_launcher.py"
    if not launcher.is_file() or not (package / "runtime" / "brain_mcp.py").is_file():
        raise LocalScopeAdapterError("H7_LOCAL_MCP_LAUNCHER_PACKAGE_INVALID")
    workspace = _normalized_directory(workspace_root, invalid_code="H7_SCOPE_INJECTION_WORKSPACE_INVALID")

    # A host-neutral adapter must state which local private state root owns
    # the contract.  Omitting it would re-enable package/default resolution
    # outside the explicit embedding boundary.
    normalized_memory = _normalized_directory(memory_root, invalid_code="H7_LOCAL_MCP_LAUNCHER_MEMORY_INVALID")

    executable = str(python_executable or sys.executable).strip()
    if not executable or "\x00" in executable or "\r" in executable or "\n" in executable:
        raise LocalScopeAdapterError("H7_LOCAL_MCP_LAUNCHER_PYTHON_INVALID")

    arguments = [
        "-X",
        "utf8",
        "-B",
        str(launcher),
        "--package-root",
        str(package),
    ]
    arguments.extend(("--memory-root", str(normalized_memory)))

    return LocalMcpLaunchSpec(
        executable=executable,
        arguments=tuple(arguments),
        cwd=workspace,
        environment=build_environment(normalized_session, source=environment_source),
    )


def launch(
    spec: LocalMcpLaunchSpec,
    **popen_kwargs: Any,
) -> subprocess.Popen[Any]:
    """Launch one adapter-owned MCP process from an immutable spec.

    ``cwd`` and ``env`` cannot be overridden because doing so would silently
    break the scope contract.  Shell execution is rejected entirely.
    """

    if not isinstance(spec, LocalMcpLaunchSpec):
        raise TypeError("spec must be LocalMcpLaunchSpec")
    if any(key in popen_kwargs for key in ("args", "executable", "cwd", "env")):
        raise LocalScopeAdapterError("H7_SCOPE_ADAPTER_LAUNCH_OVERRIDE_FORBIDDEN")
    if bool(popen_kwargs.get("shell", False)):
        raise LocalScopeAdapterError("H7_SCOPE_ADAPTER_SHELL_FORBIDDEN")
    options = dict(popen_kwargs)
    options.setdefault("stdin", subprocess.PIPE)
    options.setdefault("stdout", subprocess.PIPE)
    options.setdefault("stderr", subprocess.PIPE)
    options.setdefault("text", True)
    options.setdefault("encoding", "utf-8")
    options["cwd"] = str(spec.cwd)
    options["env"] = dict(spec.environment)
    return subprocess.Popen(list(spec.argv), **options)


def close_process(process: subprocess.Popen[Any] | None, *, timeout_seconds: float = 5.0) -> int | None:
    """Close one adapter-owned process with a final wait after kill.

    EOF is the normal teardown path.  Terminate/kill are bounded fallbacks;
    the final ``wait`` is deliberate so a Windows child cannot keep a Broker
    lock while the host cleans up its temporary state.
    """

    if process is None:
        return None
    try:
        if process.stdin is not None:
            process.stdin.close()
    except (OSError, ValueError):
        pass
    try:
        return process.wait(timeout=timeout_seconds)
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        process.terminate()
    except OSError:
        pass
    try:
        return process.wait(timeout=max(1.0, timeout_seconds / 2.0))
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        process.kill()
    except OSError:
        pass
    try:
        return process.wait(timeout=max(1.0, timeout_seconds / 2.0))
    except (OSError, subprocess.TimeoutExpired):
        return process.poll()


def verify_startup(value: Mapping[str, Any] | None) -> bool:
    """Return true only for a current bound local MCP startup handshake."""

    if not isinstance(value, Mapping):
        return False
    candidate: Mapping[str, Any] = value
    if isinstance(value.get("result"), Mapping):
        candidate = value["result"]  # type: ignore[assignment]
    if isinstance(candidate.get("liveMcpHandshake"), Mapping):
        candidate = candidate["liveMcpHandshake"]  # type: ignore[assignment]
    injection = candidate.get("scopeInjection")
    scope = candidate.get("scope")
    return bool(
        isinstance(injection, Mapping)
        and injection.get("code") == "H7_SCOPE_BOOTSTRAP_BOUND"
        and injection.get("scopeAuthorized") is True
        and isinstance(scope, Mapping)
        and scope.get("state") == "bound"
        and scope.get("scopeReady") is True
    )


__all__ = [
    "ADAPTER_SCHEMA",
    "LOCAL_SESSION_ENV",
    "LocalMcpLaunchSpec",
    "LocalScopeAdapterError",
    "SESSION_PATTERN",
    "WORKER_ENV_KEYS",
    "build_environment",
    "build_launch_spec",
    "close_process",
    "generate_session_id",
    "launch",
    "new_session_id",
    "validate_session_id",
    "verify_startup",
]
