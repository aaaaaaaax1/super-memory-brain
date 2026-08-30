"""Public, no-Hook turn-close dispatcher.

The execution contract remains the only writer/authority.  This adapter does
only three things: resolve the current scoped contract, apply the pure
turn-close policy, and (when the policy authorizes it) call the contract's
CloseTurn transaction with CAS fields.  Hooks may accelerate this path but are
not required for the state transition.
"""

from __future__ import annotations

import base64
import atexit
import hashlib
import json
import math
import os
import queue
import shutil
import signal
import re
import subprocess
import threading
import time
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from continuation_policy import decide_turn_close


SCHEMA = "super-brain.turn-close-dispatch.v1"
MAX_REFERENCE_CHARS = 240
MAX_PROGRESS_SENTENCE_CHARS = 320
MAX_PROGRESS_PHASE_CHARS = 120
MAX_PROGRESS_STEP_CHARS = 220
MAX_PROGRESS_NEXT_ACTION_CHARS = 360
MAX_PROJECT_PROGRESS_PROOF_BYTES = 32 * 1024
MAX_PROJECT_PROGRESS_ITEMS = 24
MAX_PROJECT_PROGRESS_EVIDENCE = 16
MAX_PROJECT_PROGRESS_VERIFICATIONS = 16
MAX_LATEST_USER_INSTRUCTION_CHARS = 480
# Every governed H7 mutation crosses the Python-to-PowerShell authority
# boundary at least twice (Resolve/Get plus CAS Set). Under a parallel verifier
# run, an 8-second process budget can expire just before a healthy authority
# returns. Keep the public default compact, but enforce one bounded 12-second
# floor for each transaction; callers may still request more.
MIN_AUTHORITY_TRANSACTION_TIMEOUT_SECONDS = 12.0
DEFAULT_TIMEOUT_SECONDS = 8.0
VISIBLE_PROGRESS_SOURCES = {"assistant_visible_reply", "user_attested_visible_reply"}
PHASE_CLOSEOUT_RECORD_SCHEMA = "super-brain.phase-closeout-receipt.v4"


def _compact(value: Any, maximum: int = MAX_REFERENCE_CHARS) -> str:
    text = " ".join(str(value or "").strip().split())
    text = re.sub(r"(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*", "Bearer [REDACTED]", text)
    text = re.sub(r"(?i)\bsk-[A-Za-z0-9_-]{8,}\b", "[REDACTED_KEY]", text)
    text = re.sub(
        r"(?i)\b(api[_ -]?key|password|passwd|token|secret)\s*[:=]\s*[^\s,;]+",
        r"\1=[REDACTED]",
        text,
    )
    if len(text) > maximum:
        return text[: maximum - 3].rstrip() + "..."
    return text


def _parse_json_output(text: str) -> dict[str, Any] | None:
    cleaned = str(text or "").lstrip("\ufeff").strip()
    if not cleaned:
        return None
    try:
        value = json.loads(cleaned)
        return value if isinstance(value, dict) else None
    except json.JSONDecodeError:
        pass
    for line in reversed(cleaned.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    start, end = cleaned.find("{"), cleaned.rfind("}")
    if start < 0 or end < start:
        return None
    try:
        value = json.loads(cleaned[start : end + 1])
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def _powershell() -> str:
    return "powershell.exe" if os.name == "nt" else "powershell"


def _stable_hash(value: str, length: int = 24) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:length]


def _normalize_session_key(value: str) -> str:
    candidate = str(value or "").strip()
    if not candidate:
        return ""
    if re.fullmatch(r"sid-[0-9a-f]{16,64}", candidate, re.IGNORECASE):
        return candidate.lower()
    return "sid-" + _stable_hash(candidate, 24)


def _normalize_workspace_key(value: str, *, base: Path) -> str:
    candidate = str(value or "").strip()
    if not candidate:
        return ""
    if re.fullmatch(r"ws-[0-9a-f]{24}", candidate, re.IGNORECASE):
        return candidate.lower()
    try:
        path = Path(candidate).expanduser()
        if not path.is_absolute():
            path = base / path
        normalized = str(path.resolve()).rstrip("\\/").lower()
    except OSError:
        normalized = candidate.lower()
    return "ws-" + _stable_hash(normalized, 24)


def _authority_transaction_timeout(value: float) -> float:
    """Return the bounded authority-process budget for one H7 transaction.

    This is deliberately a floor rather than a retry loop that relaxes CAS or
    proof checks.  A slow process may be retried only with the same deterministic
    transition id; the execution-contract authority still verifies revision,
    plan fingerprint, project proof, and idempotent-replay payload equality.
    """

    try:
        requested = float(value)
    except (TypeError, ValueError):
        requested = DEFAULT_TIMEOUT_SECONDS
    if not math.isfinite(requested):
        requested = DEFAULT_TIMEOUT_SECONDS
    return max(MIN_AUTHORITY_TRANSACTION_TIMEOUT_SECONDS, requested)


_AUTHORITY_WORKER_IDLE_SECONDS = 45.0
_AUTHORITY_WORKER_REQUEST_BYTES = 256 * 1024
_AUTHORITY_WORKER_RESPONSE_BYTES = 1024 * 1024
_AUTHORITY_WORKER_MAX_REQUESTS = 64
_AUTHORITY_WORKER_MARKER = "__SUPER_BRAIN_AUTHORITY_DONE__"
_AUTHORITY_WORKER_TRANSPORT_ENV = "SUPER_BRAIN_MCP_TRANSPORT"
_AUTHORITY_WORKER_TRANSPORT_VALUE = "codex_registered_v1"
_AUTHORITY_WORKER_LOCAL_ENV = "SUPER_BRAIN_LOCAL_MCP_RUNTIME"


def _parse_worker_marker(line: str, marker: str) -> int | None:
    """Accept only the exact worker completion protocol (exit 0 or 1)."""

    if not line.startswith(marker):
        return None
    value = line[len(marker):]
    return int(value) if value in {"0", "1"} else None


def _terminate_process_tree(process: subprocess.Popen[str]) -> None:
    """Terminate the worker and any authority child it started.

    ``execution-contract.ps1`` invokes a second PowerShell process for the
    task-state store.  Killing only the resident parent can therefore leave a
    mutating child alive while the caller falls back to the cold path.  Use the
    platform's tree-aware primitive first, then a bounded direct wait/fallback.
    """

    pid = int(getattr(process, "pid", 0) or 0)
    if pid > 0 and os.name == "nt":
        taskkill = shutil.which("taskkill")
        if taskkill:
            try:
                subprocess.run(
                    [taskkill, "/PID", str(pid), "/T", "/F"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2.0,
                    check=False,
                )
            except (OSError, subprocess.SubprocessError):
                pass
    elif pid > 0:
        try:
            os.killpg(os.getpgid(pid), signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass
    try:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=1.0)
    except (OSError, subprocess.TimeoutExpired):
        pass


class _AuthorityWorker:
    """One bounded in-process client for a warm PowerShell authority worker.

    The worker is deliberately a transport optimization only.  The existing
    execution-contract script remains the authority and receives the exact
    same argument list as the cold path.  A single lock serializes requests,
    while idle expiry and crash cleanup keep resident resources bounded.
    """

    def __init__(self, package_root: Path):
        self.package_root = package_root
        self.script_path = package_root / "scripts" / "execution-contract.ps1"
        self.worker_path = package_root / "scripts" / "execution-contract-worker.ps1"
        self._lock = threading.Lock()
        self._process: subprocess.Popen[str] | None = None
        self._last_used = 0.0
        self._sequence = 0
        self._request_count = 0
        self._reaper_stop: threading.Event | None = None
        self._reaper: threading.Thread | None = None

    def _ensure_reaper_locked(self) -> None:
        if self._reaper is not None and self._reaper.is_alive():
            if self._reaper_stop is None or not self._reaper_stop.is_set():
                return
            # A previous generation is already stopping.  Its event is
            # captured by that thread, so detaching it here cannot make the
            # replacement worker share a stop signal with the old thread.
            self._reaper = None
        stop_event = threading.Event()
        self._reaper_stop = stop_event
        self._reaper = threading.Thread(
            target=self._reap_idle,
            args=(stop_event,),
            name="super-brain-authority-reaper",
            daemon=True,
        )
        self._reaper.start()

    def _reap_idle(self, stop_event: threading.Event) -> None:
        """Release an unused resident authority without waiting for a call."""

        while not stop_event.wait(timeout=1.0):
            with self._lock:
                process = self._process
                # A worker can exit between requests (for example after a
                # PowerShell startup error).  Treat that as a terminal channel
                # state so the reaper does not remain resident until process
                # shutdown, and let the next invocation create a fresh one.
                if process is None or process.poll() is not None:
                    self._shutdown_locked()
                    stop_event.set()
                    if self._reaper is threading.current_thread():
                        self._reaper = None
                    return
                if self._last_used > 0 and time.monotonic() - self._last_used > _AUTHORITY_WORKER_IDLE_SECONDS:
                    self._shutdown_locked()
                    stop_event.set()
                    if self._reaper is threading.current_thread():
                        self._reaper = None
                    return

    def _shutdown_locked(self) -> None:
        process = self._process
        self._process = None
        if process is None:
            return
        try:
            if process.stdin is not None:
                process.stdin.close()
        except (OSError, ValueError):
            pass
        _terminate_process_tree(process)
        for stream in (process.stdout, process.stderr):
            try:
                if stream is not None:
                    stream.close()
            except (OSError, ValueError):
                pass

    def shutdown(self) -> None:
        with self._lock:
            if self._reaper_stop is not None:
                self._reaper_stop.set()
            self._shutdown_locked()

    def _start_locked(self) -> bool:
        if self._process is not None and self._process.poll() is None:
            return True
        self._shutdown_locked()
        if not self.script_path.is_file() or not self.worker_path.is_file():
            return False
        environment = os.environ.copy()
        environment.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
        environment.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
        environment.pop("SUPER_BRAIN_STATE_ROOT", None)
        command = [
            _powershell(),
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(self.worker_path),
            "-ScriptPath",
            str(self.script_path),
        ]
        creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        try:
            self._process = subprocess.Popen(
                command,
                # Keep the resident process anchored to the package, never to
                # a caller's temporary/project directory.  The worker restores
                # its location after each request before any caller cleanup.
                cwd=str(self.package_root),
                env=environment,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                creationflags=creation_flags,
                start_new_session=(os.name != "nt"),
            )
        except (OSError, ValueError):
            self._process = None
            return False
        # Avoid creating a resident reaper for a process that failed during
        # startup before the first request could be written.
        if self._process.poll() is not None:
            self._shutdown_locked()
            return False
        self._ensure_reaper_locked()
        self._last_used = time.monotonic()
        self._request_count = 0
        return True

    def invoke(
        self,
        arguments: list[str],
        timeout: float,
        *,
        execution_cwd: str | Path | None = None,
    ) -> tuple[int, str] | None:
        try:
            bounded_timeout = max(0.25, float(timeout))
        except (TypeError, ValueError):
            bounded_timeout = 12.0
        with self._lock:
            if self._process is not None and time.monotonic() - self._last_used > _AUTHORITY_WORKER_IDLE_SECONDS:
                self._shutdown_locked()
            if self._process is not None and self._request_count >= _AUTHORITY_WORKER_MAX_REQUESTS:
                self._shutdown_locked()
            if not self._start_locked():
                return None
            process = self._process
            if process is None or process.stdin is None or process.stdout is None:
                self._shutdown_locked()
                return None
            self._sequence = (self._sequence + 1) & 0xFFFFFFFFFFFFFFFF
            request_id = f"{self._sequence:016x}"
            # The caller supplies the already-bound project root.  Falling
            # back to the package root keeps direct legacy/unit callers
            # deterministic without consulting ambient process cwd.
            request_cwd = self.package_root
            if execution_cwd is not None:
                try:
                    candidate_cwd = Path(execution_cwd).expanduser().resolve()
                    if candidate_cwd.is_dir():
                        request_cwd = candidate_cwd
                except (OSError, ValueError):
                    pass
            request = {
                "schema": "super-brain.execution-contract-worker-request.v1",
                "id": request_id,
                "cwd": str(request_cwd),
                "args": [str(item) for item in arguments],
            }
            encoded = base64.b64encode(
                json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            ).decode("ascii")
            if len(encoded.encode("ascii")) > _AUTHORITY_WORKER_REQUEST_BYTES:
                self._shutdown_locked()
                return None
            try:
                process.stdin.write(encoded + "\n")
                process.stdin.flush()
            except (OSError, ValueError):
                self._shutdown_locked()
                return None

            result_queue: queue.Queue[tuple[int, str] | None] = queue.Queue(maxsize=1)

            def read_response() -> None:
                lines: list[str] = []
                response_bytes = 0
                marker = _AUTHORITY_WORKER_MARKER + request_id + ":"
                try:
                    while True:
                        line = process.stdout.readline()
                        if line == "":
                            result_queue.put(None)
                            return
                        clean = line.rstrip("\r\n")
                        if clean.startswith(marker):
                            exit_code = _parse_worker_marker(clean, marker)
                            if exit_code is None:
                                result_queue.put(None)
                                return
                            result_queue.put((exit_code, "\n".join(lines)))
                            return
                        response_bytes += len(line.encode("utf-8", errors="replace"))
                        if response_bytes > _AUTHORITY_WORKER_RESPONSE_BYTES:
                            result_queue.put(None)
                            return
                        lines.append(clean)
                except (OSError, ValueError):
                    result_queue.put(None)

            reader_thread = threading.Thread(
                target=read_response,
                name="super-brain-authority-reader",
                daemon=True,
            )
            reader_thread.start()
            try:
                result = result_queue.get(timeout=bounded_timeout)
            except queue.Empty:
                self._shutdown_locked()
                reader_thread.join(timeout=1.0)
                return None
            if result is None:
                self._shutdown_locked()
                reader_thread.join(timeout=1.0)
                return None
            reader_thread.join(timeout=0.25)
            self._last_used = time.monotonic()
            self._request_count += 1
            return result


_AUTHORITY_CHANNEL_LOCK = threading.Lock()
_AUTHORITY_CHANNEL: _AuthorityWorker | None = None
_AUTHORITY_CHANNEL_KEY = ""


def _shutdown_authority_channel() -> None:
    global _AUTHORITY_CHANNEL, _AUTHORITY_CHANNEL_KEY
    with _AUTHORITY_CHANNEL_LOCK:
        channel = _AUTHORITY_CHANNEL
        _AUTHORITY_CHANNEL = None
        _AUTHORITY_CHANNEL_KEY = ""
    if channel is not None:
        channel.shutdown()


def _invoke_warm_authority(
    package_root: Path,
    arguments: list[str],
    timeout: float,
    *,
    execution_cwd: str | Path | None = None,
) -> tuple[int, str] | None:
    # A one-shot CLI should not pay to create a resident process.  The
    # registered MCP is the long-lived caller for which this channel exists;
    # its child CLI bridge intentionally receives a scrubbed environment.
    registered_transport = os.environ.get(_AUTHORITY_WORKER_TRANSPORT_ENV, "").strip()
    local_mcp_runtime = os.environ.get(_AUTHORITY_WORKER_LOCAL_ENV, "").strip() == "1"
    if registered_transport != _AUTHORITY_WORKER_TRANSPORT_VALUE and not local_mcp_runtime:
        return None
    global _AUTHORITY_CHANNEL, _AUTHORITY_CHANNEL_KEY
    # A resident PowerShell process dot-sources the package scripts once at
    # startup.  Rebind it when the package is updated in place; otherwise a
    # stale worker could execute old authority code while the Python identity
    # layer already observes the new package.  The stamp is only a routing
    # key, never an authorization decision; the authority still validates its
    # own manifest and contract on every request.
    key_parts = [os.path.normcase(str(package_root))]
    for source in (
        package_root / "manifest.json",
        package_root / "scripts" / "execution-contract.ps1",
        package_root / "scripts" / "execution-contract-worker.ps1",
    ):
        try:
            stat = source.stat()
            key_parts.append(f"{stat.st_mtime_ns}:{stat.st_size}:{getattr(stat, 'st_ctime_ns', 0)}")
        except OSError:
            key_parts.append("missing")
    key = "|".join(key_parts)
    with _AUTHORITY_CHANNEL_LOCK:
        if _AUTHORITY_CHANNEL is None or _AUTHORITY_CHANNEL_KEY != key:
            previous = _AUTHORITY_CHANNEL
            _AUTHORITY_CHANNEL = _AuthorityWorker(package_root)
            _AUTHORITY_CHANNEL_KEY = key
        else:
            previous = None
        channel = _AUTHORITY_CHANNEL
    if previous is not None:
        previous.shutdown()
    if channel is None:
        return None
    return channel.invoke(arguments, timeout, execution_cwd=execution_cwd)


atexit.register(_shutdown_authority_channel)


def formal_phase_token(value: Any) -> str:
    """Return the compact formal-stage token used solely for transport lookup.

    The PowerShell execution contract remains the authority that decides
    whether a transition is allowed.  This helper only decides whether the
    runtime should look for the one deterministic H7 closeout record instead
    of scanning a state directory.
    """

    label = str(value or "").strip()
    if not label:
        return ""
    legacy = re.match(r"^(?:p(?:hase)?)\s*(\d+(?:\.\d+){0,2})(?=$|\s|[/:()\-])", label, re.IGNORECASE)
    if legacy:
        return f"P{legacy.group(1)}"
    release = re.match(
        r"^r(\d+)\s+stage\s*(\d+(?:\.\d+){0,2})(?=$|\s|[/:()\-])",
        label,
        re.IGNORECASE,
    )
    if release:
        return f"R{release.group(1)}-STAGE{release.group(2)}"
    stage = re.match(r"^stage\s*(\d+(?:\.\d+){0,2})(?=$|\s|[/:()\-])", label, re.IGNORECASE)
    return f"STAGE{stage.group(1)}" if stage else ""


def _phase_parts(token: str) -> tuple[str, tuple[int, ...]] | None:
    legacy = re.fullmatch(r"P(\d+(?:\.\d+){0,2})", token, re.IGNORECASE)
    if legacy:
        return "P", tuple(int(part) for part in legacy.group(1).split("."))
    release = re.fullmatch(r"R(\d+)-STAGE(\d+(?:\.\d+){0,2})", token, re.IGNORECASE)
    if release:
        return f"R{release.group(1)}-STAGE", tuple(int(part) for part in release.group(2).split("."))
    stage = re.fullmatch(r"STAGE(\d+(?:\.\d+){0,2})", token, re.IGNORECASE)
    if stage:
        return "STAGE", tuple(int(part) for part in stage.group(1).split("."))
    return None


def _is_forward_formal_phase_transition(previous_phase: Any, next_phase: Any) -> bool:
    previous_token = formal_phase_token(previous_phase)
    next_token = formal_phase_token(next_phase)
    previous = _phase_parts(previous_token)
    target = _phase_parts(next_token)
    if previous is None or target is None or previous[0] != target[0]:
        return False
    width = max(len(previous[1]), len(target[1]))
    left = previous[1] + (0,) * (width - len(previous[1]))
    right = target[1] + (0,) * (width - len(target[1]))
    return right > left


def is_formal_phase(value: Any) -> bool:
    return bool(formal_phase_token(value))


def _phase_closeout_authority_path(state_root: Path, contract: Mapping[str, Any]) -> Path | None:
    """Compute one opaque closeout path; never enumerate the evidence root."""

    task_id = _compact(contract.get("taskId"), 160)
    workspace = _compact(contract.get("workspaceKey"), 80)
    session = _compact(contract.get("ownerSessionKey"), 80)
    phase = formal_phase_token(contract.get("currentPhase"))
    try:
        revision = int(contract.get("revision", contract.get("contractRevision", 0)) or 0)
    except (TypeError, ValueError):
        revision = 0
    plan = contract.get("planReceipt") if isinstance(contract.get("planReceipt"), Mapping) else {}
    fingerprint = _compact(contract.get("planFingerprint") or plan.get("planFingerprint"), 96)
    visible = contract.get("visibleProgressReceipt") if isinstance(contract.get("visibleProgressReceipt"), Mapping) else {}
    visible_hash = str(visible.get("payloadHash", ""))
    if (
        not task_id
        or not workspace
        or not session
        or revision <= 0
        or not phase
        or not fingerprint
        or not re.fullmatch(r"[a-f0-9]{64}", visible_hash)
    ):
        return None
    identity = "\n".join((task_id, workspace, session, str(revision), fingerprint, phase, visible_hash))
    identity_hash = hashlib.sha256(identity.encode("utf-8")).hexdigest()
    evidence_root = (state_root / "workspace" / "runtime-state" / "phase-evidence").resolve()
    candidate = evidence_root / f"phase-closeout-v4-r{revision}-{phase.lower()}-{identity_hash[:24]}.json"
    try:
        candidate.resolve().relative_to(evidence_root)
    except ValueError:
        return None
    return candidate


def find_phase_closeout_for_transition(
    state_root: str | Path,
    current_contract: Mapping[str, Any],
    next_phase: Any,
) -> tuple[Path | None, str]:
    """Return the exact closeout required for one forward formal transition.

    This is deliberately a one-file lookup.  It does not scan historical
    closeouts, revive an old receipt, or decide that a transition is valid;
    the PowerShell CAS authority revalidates the returned file under its lock.
    """

    if not _is_forward_formal_phase_transition(current_contract.get("currentPhase"), next_phase):
        return None, "H7_PHASE_CLOSEOUT_NOT_REQUIRED"
    path = _phase_closeout_authority_path(Path(state_root).expanduser().resolve(), current_contract)
    if path is None or not path.is_file():
        return None, "H7_PHASE_CLOSEOUT_EXACT_RECORD_REQUIRED"
    try:
        if path.stat().st_size <= 0 or path.stat().st_size > 64 * 1024:
            return None, "H7_PHASE_CLOSEOUT_EXACT_RECORD_INVALID"
        receipt = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None, "H7_PHASE_CLOSEOUT_EXACT_RECORD_INVALID"
    if not isinstance(receipt, Mapping):
        return None, "H7_PHASE_CLOSEOUT_EXACT_RECORD_INVALID"
    visible = current_contract.get("visibleProgressReceipt") if isinstance(current_contract.get("visibleProgressReceipt"), Mapping) else {}
    h7 = receipt.get("h7") if isinstance(receipt.get("h7"), Mapping) else {}
    expected_phase = formal_phase_token(current_contract.get("currentPhase"))
    plan = current_contract.get("planReceipt") if isinstance(current_contract.get("planReceipt"), Mapping) else {}
    if (
        str(receipt.get("schema", "")) != PHASE_CLOSEOUT_RECORD_SCHEMA
        or str(receipt.get("taskId", "")) != str(current_contract.get("taskId", ""))
        or str(receipt.get("workspaceKey", "")) != str(current_contract.get("workspaceKey", ""))
        or str(receipt.get("ownerSessionKey", "")) != str(current_contract.get("ownerSessionKey", ""))
        or str(receipt.get("phase", "")) != expected_phase
        or int(receipt.get("contractRevision", 0) or 0) != int(current_contract.get("revision", 0) or 0)
        or str(receipt.get("planFingerprint", "")) != str(current_contract.get("planFingerprint") or plan.get("planFingerprint", ""))
        or str(h7.get("visibleProgressPayloadHash", "")) != str(visible.get("payloadHash", ""))
        or receipt.get("rawPromptStored") is not False
        or receipt.get("rawTranscriptStored") is not False
    ):
        return None, "H7_PHASE_CLOSEOUT_EXACT_RECORD_INVALID"
    return path, "H7_PHASE_CLOSEOUT_EXACT_RECORD_CURRENT"


def create_phase_closeout(
    package_root: str | Path,
    state_root: str | Path,
    *,
    task_id: str,
    workspace_key: str,
    session_key: str,
    project_root: str | Path,
    expected_revision: int,
    expected_plan_fingerprint: str,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Ask the local H7 authority to publish an idempotent v4 closeout record."""

    package = Path(package_root).expanduser().resolve()
    state = Path(state_root).expanduser().resolve()
    root = _normalize_project_root(project_root)
    # ``project_root`` is the provider-bound scope root.  Use the package
    # root only as a deterministic base when a legacy caller supplies a
    # path-like workspace key instead of its canonical ``ws-*`` form.
    workspace = _normalize_workspace_key(workspace_key, base=root or package)
    session = _normalize_session_key(session_key)
    if not workspace or not session or root is None:
        return {
            "ok": False,
            "schema": SCHEMA,
            "state": "withheld",
            "code": "H7_PHASE_CLOSEOUT_SCOPE_REQUIRED",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    if expected_revision <= 0 or not _compact(expected_plan_fingerprint, 96):
        return {
            "ok": False,
            "schema": SCHEMA,
            "state": "withheld",
            "code": "H7_PHASE_CLOSEOUT_CAS_FIELDS_REQUIRED",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    exit_code, result = _invoke_contract(
        package,
        state,
        action="CreatePhaseCloseout",
        task_id=_compact(task_id, 160),
        workspace_key=workspace,
        session_key=session,
        timeout=_authority_transaction_timeout(timeout),
        execution_cwd=root,
        extra=[
            "-ProjectRoot", str(root),
            "-ExpectedRevision", str(expected_revision),
            "-ExpectedPlanFingerprint", _compact(expected_plan_fingerprint, 96),
        ],
    )
    if exit_code != 0 or not isinstance(result, Mapping) or result.get("ok") is not True:
        return {
            "ok": False,
            "schema": SCHEMA,
            "state": "withheld",
            "code": str((result or {}).get("code", "H7_PHASE_CLOSEOUT_CREATE_FAILED")),
            "contractReason": _compact((result or {}).get("reason", ""), 160),
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    return {
        "ok": True,
        "schema": SCHEMA,
        "state": "current",
        "code": str(result.get("code", "H7_PHASE_CLOSEOUT_CREATED")),
        "phase": _compact(result.get("phase"), 120),
        "revision": int(result.get("revision", result.get("contractRevision", 0)) or 0),
        "receiptSha256": str(result.get("receiptSha256", result.get("sha256", ""))),
        "replayed": bool(result.get("replayed")),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _invoke_contract(
    package_root: Path,
    state_root: Path,
    *,
    action: str,
    task_id: str,
    workspace_key: str,
    session_key: str,
    timeout: float,
    extra: list[str] | None = None,
    execution_cwd: str | Path | None = None,
) -> tuple[int, dict[str, Any] | None]:
    script = package_root / "scripts" / "execution-contract.ps1"
    if not script.is_file():
        return 1, None
    command = [
        _powershell(),
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        "-Action",
        action,
        "-WorkspaceKey",
        workspace_key,
        "-SessionKey",
        session_key,
        "-StateRoot",
        str(state_root),
        "-NoExit",
        "-Json",
    ]
    if task_id:
        command.extend(["-TaskId", task_id])
    command.extend(extra or [])
    environment = os.environ.copy()
    # Session identity is carried by the explicit ``-SessionKey`` contract
    # argument.  Do not mirror the provider binding into ambient environment;
    # that would make a production MCP call appear dependent on a legacy
    # process variable.
    environment.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
    environment.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
    environment.pop("SUPER_BRAIN_STATE_ROOT", None)
    # Reuse one package-owned authority worker when this process serves more
    # than one governed request (the resident MCP path).  A missing, stale, or
    # timed-out worker returns ``None`` and falls through to the unchanged cold
    # subprocess path below, so optimization failure cannot weaken authority.
    script_argument_index = command.index(str(script)) + 1
    # Scope-bearing callers pass the provider's project root explicitly.  The
    # package root is a deterministic compatibility fallback for direct unit
    # calls; ambient process cwd is never used to select a production scope.
    effective_cwd = package_root
    if execution_cwd is not None:
        try:
            candidate_cwd = Path(execution_cwd).expanduser().resolve()
            if candidate_cwd.is_dir():
                effective_cwd = candidate_cwd
        except (OSError, ValueError):
            pass
    warm_result = _invoke_warm_authority(
        package_root,
        command[script_argument_index:],
        timeout,
        execution_cwd=effective_cwd,
    )
    if warm_result is not None:
        parsed_warm = _parse_json_output(warm_result[1])
        # A marker with non-JSON payload is a transport/protocol failure, not
        # an authority decision.  Let the unchanged cold path re-establish the
        # result instead of turning a recoverable warm-channel fault into a
        # false transaction failure.
        if parsed_warm is not None:
            return warm_result[0], parsed_warm
    try:
        completed = subprocess.run(
            command,
        # Use the already-bound project root for relative authority inputs.
        # This keeps the subprocess deterministic and prevents ambient cwd
        # from redirecting a production MCP operation.
        cwd=str(effective_cwd),
            env=environment,
            input="",
            text=True,
            # execution-contract.ps1 explicitly emits UTF-8.  Relying on the
            # Windows ANSI locale turns a valid Chinese progress checkpoint
            # into a false transaction failure before the authority sees it.
            encoding="utf-8",
            errors="strict",
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=max(0.25, float(timeout)),
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return 1, None
    return completed.returncode, _parse_json_output(completed.stdout)


def _base_result(
    *,
    policy: dict[str, Any],
    resolution: dict[str, Any] | None,
    code: str = "",
    state_mutated: bool = False,
) -> dict[str, Any]:
    return {
        "ok": True,
        "schema": SCHEMA,
        "code": code or "TURN_CLOSE_DISPATCH_POLICY_ONLY",
        "stateMutated": bool(state_mutated),
        "policy": policy,
        "resolution": {
            "taskId": _compact((resolution or {}).get("taskId"), 120),
            "focusId": _compact((resolution or {}).get("focusId"), 120),
            "focusLabel": _compact((resolution or {}).get("focusLabel"), 140),
            "contractRevision": int((resolution or {}).get("contractRevision", 0) or 0),
            "planFingerprint": _compact((resolution or {}).get("planFingerprint"), 96),
            "sessionAccess": _compact((resolution or {}).get("sessionAccess"), 48),
            "actionAuthorization": _compact((resolution or {}).get("actionAuthorization"), 32),
        },
        "transition": None,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _transition_summary(value: dict[str, Any] | None, *, transition_id: str = "") -> dict[str, Any]:
    value = value if isinstance(value, dict) else {}
    last = value.get("lastTransition") if isinstance(value.get("lastTransition"), dict) else {}
    resolved_id = _compact(
        value.get("replayedTransitionId") or value.get("transitionId") or last.get("transitionId") or transition_id,
        120,
    )
    return {
        "ok": value.get("ok") is True,
        "schema": _compact(value.get("schema") or "super-brain.execution-contract.v1", 96),
        "action": _compact(value.get("transitionAction") or last.get("action") or "ResumeParent", 48),
        "transitionId": resolved_id,
        "revision": int(value.get("revision", value.get("originalResultRevision", 0)) or 0),
        "taskId": _compact(value.get("taskId"), 160),
        "focusId": _compact(value.get("focusId"), 120),
        "focusLabel": _compact(value.get("focusLabel"), 140),
        "nextAction": _compact(value.get("nextAction"), 280),
        "currentStep": _compact(value.get("currentStep"), 240),
        "idempotentReplay": bool(value.get("idempotentReplay")),
        "resumedBranchStatus": _compact(value.get("resumedBranchStatus"), 32),
        "decision": _compact(value.get("decision"), 64),
        "policyDecision": _compact(value.get("policyDecision"), 96),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _normalize_progress_checkpoint(value: Any) -> tuple[dict[str, str] | None, str]:
    """Accept one bounded assistant-authored state checkpoint.

    This is intentionally not a prompt or transcript channel.  The host must
    provide an already-visible summary of the assistant's own progress, with
    exactly the fields needed to restore the active workline.  H7 rejects
    normalization here: a recovery anchor must never become text the user did
    not actually see.
    """

    if not isinstance(value, Mapping):
        return None, "H7_PROGRESS_CHECKPOINT_INVALID"
    required = {
        "last_confirmed_sentence": MAX_PROGRESS_SENTENCE_CHARS,
        "current_phase": MAX_PROGRESS_PHASE_CHARS,
        "current_step": MAX_PROGRESS_STEP_CHARS,
        "next_action": MAX_PROGRESS_NEXT_ACTION_CHARS,
        "source": 64,
    }
    if set(value) != set(required):
        return None, "H7_PROGRESS_CHECKPOINT_FIELDS_INVALID"
    normalized: dict[str, str] = {}
    for field, maximum in required.items():
        raw = value.get(field)
        if not isinstance(raw, str):
            return None, "H7_PROGRESS_CHECKPOINT_FIELDS_INVALID"
        if field == "source":
            if raw not in VISIBLE_PROGRESS_SOURCES:
                return None, "H7_PROGRESS_CHECKPOINT_SOURCE_INVALID"
            normalized[field] = raw
            continue
        compact = _compact(raw, maximum)
        if not compact or compact != raw or "\n" in raw or "\r" in raw:
            return None, "H7_PROGRESS_CHECKPOINT_FIELDS_INVALID"
        normalized[field] = compact
    return normalized, "H7_PROGRESS_CHECKPOINT_CURRENT"


def _normalize_latest_user_instruction(value: Any) -> tuple[str, str]:
    """Accept one compact, redacted current-instruction reconciliation input.

    This is deliberately narrower than a transcript channel.  The caller may
    provide only the current user instruction that has already been scoped to
    the active task; the contract's ``ObserveUser``/``Set`` path redacts and
    binds it as an instruction anchor.  Checkpoint receipts retain only the
    hash, never this text.
    """

    if value is None:
        return "", "H7_LATEST_INSTRUCTION_NOT_SUPPLIED"
    if not isinstance(value, str):
        return "", "H7_LATEST_INSTRUCTION_INVALID"
    compact = _compact(value, MAX_LATEST_USER_INSTRUCTION_CHARS)
    if not compact or "\n" in compact or "\r" in compact:
        return "", "H7_LATEST_INSTRUCTION_INVALID"
    return compact, "H7_LATEST_INSTRUCTION_CURRENT"


def _checklist_key(value: Any) -> str:
    return " ".join(str(value or "").strip().split()).casefold()


def _write_canonical_status_mutation(
    *,
    state_root: Path,
    current: Mapping[str, Any],
    proof: Mapping[str, Any] | None,
    transition_id: str,
    latest_user_instruction: str,
    task_id: str = "",
    workspace_key: str = "",
    session_key: str = "",
) -> tuple[str | None, str]:
    """Create one CAS-bound canonical completion mutation from H7 proof.

    A project-progress proof is already required to bind every completed item
    to project evidence and passed verification.  When the active canonical
    plan names those same items, translate that verified delta into the
    existing ``set_status`` envelope instead of leaving a completed phase
    projected as ``pending``.  Unknown or ambiguous item keys fail closed.
    """

    if not isinstance(proof, Mapping):
        return None, "H7_CANONICAL_STATUS_NOT_APPLICABLE"
    plan = current.get("canonicalPlan")
    if not isinstance(plan, Mapping):
        return None, "H7_CANONICAL_STATUS_NOT_APPLICABLE"
    items = plan.get("items")
    completed_items = proof.get("completedItems")
    if not isinstance(items, list) or not isinstance(completed_items, list):
        return None, "H7_CANONICAL_STATUS_NOT_APPLICABLE"
    if not completed_items:
        return None, "H7_CANONICAL_STATUS_NOT_APPLICABLE"

    by_key: dict[str, dict[str, Any]] = {}
    for item in items:
        if not isinstance(item, Mapping):
            return None, "H7_CANONICAL_STATUS_PLAN_INVALID"
        item_id = str(item.get("itemId", "")).strip()
        key = _checklist_key(item.get("label"))
        if not item_id or not key or key in by_key:
            return None, "H7_CANONICAL_STATUS_PLAN_INVALID"
        by_key[key] = dict(item)

    target_ids: list[str] = []
    evidence_refs: list[str] = []
    seen_keys: set[str] = set()
    for completed in completed_items:
        if not isinstance(completed, Mapping):
            return None, "H7_CANONICAL_STATUS_COMPLETED_ITEM_INVALID"
        key = _checklist_key(completed.get("itemKey"))
        if not key or key in seen_keys or key not in by_key:
            return None, "H7_CANONICAL_STATUS_ITEM_MAPPING_WITHHELD"
        seen_keys.add(key)
        planned = by_key[key]
        status = str(planned.get("status", ""))
        if status not in {"pending", "in_progress", "completed"}:
            return None, "H7_CANONICAL_STATUS_ITEM_STATE_INVALID"
        if status != "completed":
            target_ids.append(str(planned["itemId"]))
        refs = completed.get("evidenceRefs")
        if not isinstance(refs, list) or not refs:
            return None, "H7_CANONICAL_STATUS_EVIDENCE_REQUIRED"
        for reference in refs:
            compact_ref = _compact(reference, 160)
            if compact_ref and compact_ref not in evidence_refs:
                evidence_refs.append(compact_ref)

    if not target_ids:
        return None, "H7_CANONICAL_STATUS_ALREADY_CURRENT"
    if not latest_user_instruction:
        latest_user_instruction = _compact(current.get("latestUserInstruction"), MAX_LATEST_USER_INSTRUCTION_CHARS)
    if not latest_user_instruction:
        return None, "H7_CANONICAL_STATUS_INSTRUCTION_REQUIRED"

    try:
        revision = int(current.get("revision", 0) or 0)
        generation = int(plan.get("generation", 0) or 0)
    except (TypeError, ValueError):
        return None, "H7_CANONICAL_STATUS_PLAN_INVALID"
    plan_id = str(plan.get("planId", "")).strip()
    fingerprint = str(plan.get("currentFingerprint", "")).strip()
    if revision <= 0 or generation <= 0 or not plan_id or not fingerprint:
        return None, "H7_CANONICAL_STATUS_PLAN_INVALID"

    task_instance_id = _compact(current.get("taskInstanceId"), 96)
    scoped_task_id = _compact(task_id or current.get("taskId"), 160)
    scoped_workspace_key = _compact(workspace_key or current.get("workspaceKey"), 96)
    scoped_session_key = _compact(session_key or current.get("ownerSessionKey"), 96)
    if not all((scoped_task_id, task_instance_id, scoped_workspace_key, scoped_session_key, transition_id)):
        return None, "H7_CANONICAL_STATUS_SCOPE_REQUIRED"

    scope = {
        "taskId": scoped_task_id,
        "taskInstanceId": task_instance_id,
        "workspaceKey": scoped_workspace_key,
        "ownerSessionKey": scoped_session_key,
    }
    envelope = {
        "schema": "super-brain.canonical-plan-mutation.v2",
        "scope": scope,
        "targetScope": "canonical_main",
        "operation": "set_status",
        "targetItemIds": target_ids,
        "items": [],
        "status": "completed",
        "evidenceRefs": evidence_refs[:6],
        "approvalSource": "verified_status_transition",
        "userInstructionFingerprint": _stable_hash(latest_user_instruction, 16),
        "expectedPlanId": plan_id,
        "expectedGeneration": generation,
        "expectedRevision": revision,
        "expectedFingerprint": fingerprint,
        "transitionId": transition_id,
    }
    envelope["payloadHash"] = hashlib.sha256(
        json.dumps(envelope, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    mutation_dir = state_root / "workspace" / "runtime-state" / "canonical-mutations"
    mutation_dir.mkdir(parents=True, exist_ok=True)
    path_seed = json.dumps(
        {"scope": scope, "transitionId": transition_id},
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    path = mutation_dir / ("checkpoint-" + _stable_hash(path_seed, 32) + ".json")
    if path.exists():
        try:
            existing = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            return None, "H7_CANONICAL_STATUS_MUTATION_CONFLICT"
        if isinstance(existing, Mapping) and str(existing.get("payloadHash", "")) == str(envelope["payloadHash"]):
            return str(path), "H7_CANONICAL_STATUS_MUTATION_READY"
        return None, "H7_CANONICAL_STATUS_MUTATION_CONFLICT"
    temporary = path.with_suffix(".tmp")
    try:
        temporary.write_text(json.dumps(envelope, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
        os.replace(temporary, path)
    except OSError:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        return None, "H7_CANONICAL_STATUS_MUTATION_WRITE_FAILED"
    return str(path), "H7_CANONICAL_STATUS_MUTATION_READY"


def _project_progress_text(value: Any, maximum: int) -> str | None:
    if not isinstance(value, str):
        return None
    compact = _compact(value, maximum)
    # The input is a structured assistant proof, not a lossy prompt transport.
    # Reject values that need normalization/redaction instead of changing the
    # material the contract will hash and bind.
    return compact if compact and compact == value else None


def _normalize_project_progress_proof(value: Any) -> tuple[dict[str, Any] | None, str]:
    """Validate bounded H7 project-progress input before Base64 transport.

    The PowerShell authority performs the live project-file/hash validation and
    emits the final proof.  This boundary only accepts the fixed, non-prompt
    input shape so a malformed or secret-bearing object never reaches durable
    state through the command line.
    """

    if not isinstance(value, Mapping):
        return None, "H7_PROJECT_PROGRESS_INPUT_INVALID"
    expected = {
        "schema",
        "phase",
        "currentStep",
        "completedItems",
        "projectEvidence",
        "verificationResults",
        "nextAction",
    }
    if set(value) != expected or value.get("schema") != "super-brain.project-progress-input.v1":
        return None, "H7_PROJECT_PROGRESS_INPUT_FIELDS_INVALID"
    phase = _project_progress_text(value.get("phase"), MAX_PROGRESS_PHASE_CHARS)
    current_step = _project_progress_text(value.get("currentStep"), MAX_PROGRESS_STEP_CHARS)
    next_action = _project_progress_text(value.get("nextAction"), MAX_PROGRESS_NEXT_ACTION_CHARS)
    completed_items = value.get("completedItems")
    project_evidence = value.get("projectEvidence")
    verification_results = value.get("verificationResults")
    if (
        not phase
        or not current_step
        or not next_action
        or not isinstance(completed_items, list)
        or not isinstance(project_evidence, list)
        or not isinstance(verification_results, list)
        or len(completed_items) > MAX_PROJECT_PROGRESS_ITEMS
        or len(project_evidence) > MAX_PROJECT_PROGRESS_EVIDENCE
        or len(verification_results) > MAX_PROJECT_PROGRESS_VERIFICATIONS
    ):
        return None, "H7_PROJECT_PROGRESS_INPUT_FIELDS_INVALID"
    evidence_refs: set[str] = set()
    normalized_evidence: list[dict[str, str]] = []
    for item in project_evidence:
        if not isinstance(item, Mapping) or set(item) != {"kind", "relativePath", "sha256"}:
            return None, "H7_PROJECT_PROGRESS_INPUT_EVIDENCE_INVALID"
        relative_path = item.get("relativePath")
        digest = item.get("sha256")
        if (
            item.get("kind") != "project_file"
            or not isinstance(relative_path, str)
            or not isinstance(digest, str)
            or len(relative_path) > 240
            or not relative_path
            or relative_path.startswith(("/", "\\"))
            or ":" in relative_path
            or any(part in {"", ".", ".."} for part in relative_path.replace("\\", "/").split("/"))
            or not re.fullmatch(r"[a-f0-9]{64}", digest)
        ):
            return None, "H7_PROJECT_PROGRESS_INPUT_EVIDENCE_INVALID"
        normalized_path = relative_path.replace("\\", "/")
        reference = f"project:file:{normalized_path}@sha256:{digest}"
        if reference in evidence_refs:
            return None, "H7_PROJECT_PROGRESS_INPUT_EVIDENCE_INVALID"
        evidence_refs.add(reference)
        normalized_evidence.append({"kind": "project_file", "relativePath": normalized_path, "sha256": digest})
    verification_by_id: dict[str, str] = {}
    normalized_verifications: list[dict[str, str]] = []
    for item in verification_results:
        if not isinstance(item, Mapping) or set(item) != {"id", "status"}:
            return None, "H7_PROJECT_PROGRESS_INPUT_VERIFICATION_INVALID"
        identifier = item.get("id")
        status = item.get("status")
        if (
            not isinstance(identifier, str)
            or not re.fullmatch(r"[A-Za-z0-9._:-]{1,120}", identifier)
            or status not in {"passed", "failed", "not_run"}
            or identifier in verification_by_id
        ):
            return None, "H7_PROJECT_PROGRESS_INPUT_VERIFICATION_INVALID"
        verification_by_id[identifier] = str(status)
        normalized_verifications.append({"id": identifier, "status": str(status)})
    seen_items: set[str] = set()
    normalized_items: list[dict[str, Any]] = []
    for item in completed_items:
        if not isinstance(item, Mapping) or set(item) != {"itemKey", "evidenceRefs", "verificationIds"}:
            return None, "H7_PROJECT_PROGRESS_INPUT_COMPLETED_ITEM_INVALID"
        item_key = _project_progress_text(item.get("itemKey"), 180)
        item_refs = item.get("evidenceRefs")
        verification_ids = item.get("verificationIds")
        normalized_key = " ".join(str(item_key or "").split()).lower()
        if (
            not item_key
            or not normalized_key
            or normalized_key in seen_items
            or not isinstance(item_refs, list)
            or not isinstance(verification_ids, list)
            or not item_refs
            or not verification_ids
            or len(item_refs) > 8
            or len(verification_ids) > 8
            or any(not isinstance(reference, str) or reference not in evidence_refs for reference in item_refs)
            or any(not isinstance(identifier, str) or verification_by_id.get(identifier) != "passed" for identifier in verification_ids)
            or len(set(item_refs)) != len(item_refs)
            or len(set(verification_ids)) != len(verification_ids)
        ):
            return None, "H7_PROJECT_PROGRESS_INPUT_COMPLETED_ITEM_INVALID"
        seen_items.add(normalized_key)
        normalized_items.append(
            {"itemKey": normalized_key, "evidenceRefs": list(item_refs), "verificationIds": list(verification_ids)}
        )
    normalized: dict[str, Any] = {
        "schema": "super-brain.project-progress-input.v1",
        "phase": phase,
        "currentStep": current_step,
        "completedItems": normalized_items,
        "projectEvidence": normalized_evidence,
        "verificationResults": normalized_verifications,
        "nextAction": next_action,
    }
    try:
        serialized = json.dumps(normalized, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError):
        return None, "H7_PROJECT_PROGRESS_INPUT_INVALID"
    if len(serialized) > MAX_PROJECT_PROGRESS_PROOF_BYTES:
        return None, "H7_PROJECT_PROGRESS_INPUT_TOO_LARGE"
    return normalized, "H7_PROJECT_PROGRESS_INPUT_CURRENT"


def _normalize_project_root(value: str | Path | None) -> Path | None:
    try:
        # Production turn paths pass the provider-bound project root.  A
        # package-root fallback keeps old direct dispatcher tests/callers
        # deterministic while avoiding ambient cwd as an identity source.
        root = (
            Path(value).expanduser().resolve()
            if value is not None
            else Path(__file__).resolve().parents[1]
        )
    except (OSError, ValueError):
        return None
    return root if root.is_dir() else None


def _reconcile_progress_checkpoint(
    package_root: Path,
    state_root: Path,
    *,
    task_id: str,
    workspace_key: str,
    session_key: str,
    checkpoint: Mapping[str, str],
    transition_id: str,
    previous_revision: int,
    timeout: float,
    execution_cwd: str | Path | None = None,
) -> dict[str, Any] | None:
    """Recognize the narrow case where a timed-out Set already committed.

    A Windows PowerShell child may finish the atomic write just after the
    launcher times out.  Treat that as success only when the authoritative
    contract contains the deterministic transition id, all five exact
    source-qualified checkpoint fields, and its visible-progress receipt.
    Any other uncertain result remains failed closed.
    """

    get_code, reconciled = _invoke_contract(
        package_root,
        state_root,
        action="Get",
        task_id=task_id,
        workspace_key=workspace_key,
        session_key=session_key,
        timeout=timeout,
        execution_cwd=execution_cwd,
    )
    if get_code != 0 or not isinstance(reconciled, dict) or reconciled.get("ok") is not True:
        return None
    receipts = reconciled.get("transitionReceipts")
    has_transition = isinstance(receipts, list) and any(
        isinstance(receipt, Mapping) and str(receipt.get("transitionId", "")) == transition_id
        for receipt in receipts
    )
    matches_checkpoint = (
        str(reconciled.get("lastConfirmedSentence", "")) == checkpoint["last_confirmed_sentence"]
        and str(reconciled.get("lastConfirmedSource", "")) == checkpoint["source"]
        and str(reconciled.get("currentPhase", "")) == checkpoint["current_phase"]
        and str(reconciled.get("currentStep", "")) == checkpoint["current_step"]
        and str(reconciled.get("nextAction", "")) == checkpoint["next_action"]
    )
    visible = reconciled.get("visibleProgressReceipt") if isinstance(reconciled.get("visibleProgressReceipt"), Mapping) else {}
    receipt_matches = (
        str(visible.get("source", "")) == checkpoint["source"]
        and str(visible.get("sentenceHash", "")) == hashlib.sha256(checkpoint["last_confirmed_sentence"].encode("utf-8")).hexdigest()
        and str(visible.get("currentPhase", "")) == checkpoint["current_phase"]
        and str(visible.get("currentStep", "")) == checkpoint["current_step"]
        and str(visible.get("nextAction", "")) == checkpoint["next_action"]
        and str(visible.get("transitionId", "")) == transition_id
    )
    if not has_transition or not matches_checkpoint or not receipt_matches:
        return None
    try:
        reconciled_revision = int(reconciled.get("revision", previous_revision) or previous_revision)
    except (TypeError, ValueError):
        reconciled_revision = previous_revision
    return {
        "ok": True,
        "schema": SCHEMA,
        "code": "H7_PROGRESS_CHECKPOINT_RECONCILED",
        "stateMutated": reconciled_revision > previous_revision,
        "taskId": _compact(reconciled.get("taskId") or task_id, 160),
        "revision": reconciled_revision,
        "transitionId": transition_id,
        "lastConfirmedSource": checkpoint["source"],
        "visibleProgress": {
            "state": "current",
            "source": checkpoint["source"],
            "sentenceHash": hashlib.sha256(checkpoint["last_confirmed_sentence"].encode("utf-8")).hexdigest(),
            "payloadHash": str(visible.get("payloadHash", "")),
            "projectProgressPayloadHash": str(visible.get("projectProgressPayloadHash", "")),
        },
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def record_progress_checkpoint(
    package_root: str | Path,
    state_root: str | Path,
    *,
    task_id: str = "",
    workspace_key: str = "",
    session_key: str = "",
    progress_checkpoint: Mapping[str, Any] | None = None,
    project_progress_proof: Mapping[str, Any] | None = None,
    latest_user_instruction: str | None = None,
    project_root: str | Path | None = None,
    current_contract: Mapping[str, Any] | None = None,
    transition_id: str = "",
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Atomically bind latest assistant progress to the active H7 contract.

    The old prompt hook could infer arbitrary user text.  H7 must not do that:
    it accepts only a five-field, source-qualified assistant checkpoint and writes it
    through the existing CAS-protected execution-contract authority.
    """

    package = Path(package_root).expanduser().resolve()
    state = Path(state_root).expanduser().resolve()
    transaction_timeout = _authority_transaction_timeout(timeout)
    root = _normalize_project_root(project_root)
    workspace = _normalize_workspace_key(workspace_key, base=root or package)
    session = _normalize_session_key(session_key)
    checkpoint, checkpoint_code = _normalize_progress_checkpoint(progress_checkpoint)
    if checkpoint is None:
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": checkpoint_code,
            "stateMutated": False,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    normalized_instruction = ""
    if latest_user_instruction is not None:
        normalized_instruction, instruction_code = _normalize_latest_user_instruction(latest_user_instruction)
        if not normalized_instruction:
            return {
                "ok": False,
                "schema": SCHEMA,
                "code": instruction_code,
                "stateMutated": False,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
    proof: dict[str, Any] | None = None
    proof_serialized = ""
    if project_progress_proof is not None:
        proof, proof_code = _normalize_project_progress_proof(project_progress_proof)
        if proof is None:
            return {
                "ok": False,
                "schema": SCHEMA,
                "code": proof_code,
                "stateMutated": False,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        proof_serialized = json.dumps(proof, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
    if root is None:
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": "H7_PROJECT_PROGRESS_ROOT_REQUIRED",
            "stateMutated": False,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    if not workspace or not session:
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": "H7_PROGRESS_CHECKPOINT_SCOPE_REQUIRED",
            "stateMutated": False,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }

    requested_task = _compact(task_id, 160)

    # ``open_turn`` has already read and bound the exact local contract for
    # this same turn.  Reuse that private, stack-local snapshot as a CAS hint
    # for the following Set.  PowerShell still re-reads the contract under its
    # lock and enforces ExpectedRevision/ExpectedPlanFingerprint, so this is
    # only a transport optimization and cannot authorize stale state.  Keep
    # canonical-plan status transitions on the original Get path because they
    # need a mutation envelope derived from the authoritative snapshot.
    hinted_current: dict[str, Any] | None = None
    canonical_status_transition = False
    formal_phase_transition = False
    if isinstance(current_contract, Mapping) and requested_task:
        candidate = dict(current_contract)
        candidate_task = _compact(candidate.get("taskId"), 160)
        candidate_workspace = _compact(candidate.get("workspaceKey"), 96).lower()
        candidate_session = _compact(candidate.get("ownerSessionKey"), 96).lower()
        candidate_plan = candidate.get("canonicalPlan")
        candidate_completed = proof.get("completedItems") if isinstance(proof, Mapping) else None
        canonical_status_transition = (
            isinstance(candidate_plan, Mapping)
            and isinstance(candidate_completed, list)
            and bool(candidate_completed)
        )
        formal_phase_transition = _is_forward_formal_phase_transition(
            candidate.get("currentPhase"),
            checkpoint.get("current_phase"),
        )
        try:
            candidate_revision = int(candidate.get("revision", candidate.get("contractRevision", 0)) or 0)
        except (TypeError, ValueError):
            candidate_revision = 0
        candidate_fingerprint = ""
        plan_receipt_hint = candidate.get("planReceipt")
        if isinstance(plan_receipt_hint, Mapping):
            candidate_fingerprint = _compact(
                candidate.get("planFingerprint") or plan_receipt_hint.get("planFingerprint"),
                96,
            )
        else:
            candidate_fingerprint = _compact(candidate.get("planFingerprint"), 96)
        if (
            candidate.get("ok") is True
            and candidate_task == requested_task
            and candidate_workspace == workspace.lower()
            and candidate_session == session.lower()
            and candidate_revision > 0
            and candidate_fingerprint
            and not canonical_status_transition
            and not formal_phase_transition
        ):
            hinted_current = candidate

    if hinted_current is not None:
        get_code, current = 0, hinted_current
        contract_read_path = "in_process_hint"
    else:
        get_code, current = _invoke_contract(
            package,
            state,
            action="Get",
            task_id=requested_task,
            workspace_key=workspace,
            session_key=session,
            timeout=transaction_timeout,
            execution_cwd=root,
        )
        contract_read_path = "authority_get"
    if get_code != 0 or not isinstance(current, dict) or current.get("ok") is not True:
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": "H7_PROGRESS_CHECKPOINT_CONTRACT_UNAVAILABLE",
            "stateMutated": False,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    resolved_task = _compact(current.get("taskId") or requested_task, 160)
    try:
        revision = int(current.get("revision", current.get("contractRevision", 0)) or 0)
    except (TypeError, ValueError):
        revision = 0
    plan_receipt = current.get("planReceipt") if isinstance(current.get("planReceipt"), Mapping) else {}
    fingerprint = _compact(current.get("planFingerprint") or plan_receipt.get("planFingerprint"), 96)
    if not resolved_task or revision <= 0 or not fingerprint:
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": "H7_PROGRESS_CHECKPOINT_CAS_FIELDS_MISSING",
            "stateMutated": False,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    # A forward formal stage transition may consume exactly one closeout.  Do
    # the bounded deterministic lookup before any derived canonical-status
    # write; ordinary checkpoints do not touch phase-evidence at all.  The
    # PowerShell CAS authority still validates and consumes the file under its
    # contract lock, so this adapter cannot turn a readable file into approval.
    phase_closeout_path, phase_closeout_code = find_phase_closeout_for_transition(
        state,
        current,
        checkpoint["current_phase"],
    )
    if phase_closeout_code == "H7_PHASE_CLOSEOUT_EXACT_RECORD_REQUIRED":
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": phase_closeout_code,
            "stateMutated": False,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    if phase_closeout_code == "H7_PHASE_CLOSEOUT_EXACT_RECORD_INVALID":
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": phase_closeout_code,
            "stateMutated": False,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    # A latest instruction carried by a checkpoint is not a mere observation:
    # it is the scoped authorization being bound to this exact CAS mutation.
    # Passing it to ``Set`` without the already-resolved current work-line
    # mapping makes PowerShell correctly mark the contract as pending
    # reconciliation *after* the checkpoint has committed.  That produces the
    # false-looking outcome "write succeeded but H7 reopened withheld".  Bind
    # only the current contract's concrete line metadata, never inferred text
    # from the caller, so the authority can validate the same instruction and
    # action in one transaction.
    instruction_mapping: dict[str, str] = {}
    if normalized_instruction:
        instruction_mapping = {
            "focusId": _compact(current.get("focusId"), 120),
            "focusLabel": _compact(current.get("focusLabel"), 120),
            "assistantCommitment": _compact(current.get("assistantCommitment"), 480),
        }
        # ``FocusId`` is the authority's required work-line selector.  Label
        # and commitment are useful audit context when an older valid contract
        # has them, but must not turn their historical absence into a new
        # blocker.
        if not instruction_mapping["focusId"]:
            return {
                "ok": False,
                "schema": SCHEMA,
                "code": "H7_PROGRESS_CHECKPOINT_INSTRUCTION_MAPPING_REQUIRED",
                "stateMutated": False,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
    stable_payload = json.dumps(
        {
            "taskId": resolved_task,
            "workspaceKey": workspace,
            "ownerSessionKey": session,
            "checkpoint": checkpoint,
            "projectProgressInputHash": hashlib.sha256(proof_serialized.encode("utf-8")).hexdigest() if proof_serialized else "",
            "latestUserInstructionHash": hashlib.sha256(normalized_instruction.encode("utf-8")).hexdigest() if normalized_instruction else "",
            "instructionMapping": instruction_mapping,
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    resolved_transition = _compact(transition_id, 120) or (
        "h7-progress-" + hashlib.sha256(stable_payload.encode("utf-8")).hexdigest()[:32]
    )
    transport_checkpoint = base64.b64encode(
        json.dumps(checkpoint, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).decode("ascii")
    transport_proof = base64.b64encode(proof_serialized.encode("utf-8")).decode("ascii") if proof_serialized else ""
    canonical_mutation_path, canonical_mutation_code = _write_canonical_status_mutation(
        state_root=state,
        current=current,
        proof=proof,
        transition_id=resolved_transition,
        latest_user_instruction=normalized_instruction,
        task_id=resolved_task,
        workspace_key=workspace,
        session_key=session,
    )
    if canonical_mutation_code not in {
        "H7_CANONICAL_STATUS_NOT_APPLICABLE",
        "H7_CANONICAL_STATUS_ALREADY_CURRENT",
        "H7_CANONICAL_STATUS_MUTATION_READY",
    }:
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": canonical_mutation_code,
            "stateMutated": False,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    set_extra = [
        "-ProgressCheckpointBase64", transport_checkpoint,
        "-ProjectRoot", str(root),
        "-ExpectedRevision", str(revision),
        "-ExpectedPlanFingerprint", fingerprint,
        "-TransitionId", resolved_transition,
        "-Source", "turn-runtime:assistant-progress-checkpoint",
    ]
    if phase_closeout_path is not None:
        set_extra.extend(["-PhaseCloseoutPath", str(phase_closeout_path)])
    if transport_proof:
        set_extra.extend(["-ProjectProgressProofBase64", transport_proof])
    if normalized_instruction:
        set_extra.extend(
            [
                "-LatestUserInstruction",
                normalized_instruction,
                "-InstructionMode",
                "continue",
                "-FocusId",
                instruction_mapping["focusId"],
            ]
        )
        if instruction_mapping["focusLabel"]:
            set_extra.extend(["-FocusLabel", instruction_mapping["focusLabel"]])
        if instruction_mapping["assistantCommitment"]:
            set_extra.extend(["-AssistantCommitment", instruction_mapping["assistantCommitment"]])
    if canonical_mutation_path:
        set_extra.extend(["-CanonicalMutationPath", canonical_mutation_path])
    set_code, updated = _invoke_contract(
        package,
        state,
        action="Set",
        task_id=resolved_task,
        workspace_key=workspace,
        session_key=session,
        timeout=transaction_timeout,
        execution_cwd=root,
        extra=set_extra,
    )
    if set_code != 0 or not isinstance(updated, dict) or updated.get("ok") is not True:
        reconciled = _reconcile_progress_checkpoint(
            package,
            state,
            task_id=resolved_task,
            workspace_key=workspace,
            session_key=session,
            checkpoint=checkpoint,
            transition_id=resolved_transition,
            previous_revision=revision,
            timeout=transaction_timeout,
            execution_cwd=root,
        )
        if reconciled is not None:
            return reconciled
        if updated is not None:
            return {
                "ok": False,
                "schema": SCHEMA,
                "code": "H7_PROGRESS_CHECKPOINT_TRANSACTION_FAILED",
                "contractCode": str(updated.get("code", "")),
                "contractReason": _compact(updated.get("reason", ""), 160),
                "stateMutated": False,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        # A transport failure may happen before PowerShell starts or after it
        # commits.  Retry once with the *same* deterministic transition id and
        # payload.  The authority treats an already committed matching Set as
        # an idempotent replay; any changed revision/proof/fingerprint remains
        # rejected by its normal CAS guards.  This adds no weaker mutation path.
        retry_code, retried = _invoke_contract(
            package,
            state,
            action="Set",
            task_id=resolved_task,
            workspace_key=workspace,
            session_key=session,
            timeout=transaction_timeout,
            execution_cwd=root,
            extra=set_extra,
        )
        if retry_code == 0 and isinstance(retried, dict) and retried.get("ok") is True:
            updated = retried
        else:
            reconciled = _reconcile_progress_checkpoint(
                package,
                state,
                task_id=resolved_task,
                workspace_key=workspace,
                session_key=session,
                checkpoint=checkpoint,
                transition_id=resolved_transition,
                previous_revision=revision,
                timeout=transaction_timeout,
                execution_cwd=root,
            )
            if reconciled is not None:
                return reconciled
            failure = retried if isinstance(retried, dict) else updated
            return {
                "ok": False,
                "schema": SCHEMA,
                "code": "H7_PROGRESS_CHECKPOINT_TRANSACTION_FAILED",
                "contractCode": str((failure or {}).get("code", "")) if isinstance(failure, dict) else "",
                "contractReason": _compact((failure or {}).get("reason", ""), 160) if isinstance(failure, dict) else "",
                "stateMutated": False,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
    return {
        "ok": True,
        "schema": SCHEMA,
        "code": "H7_PROGRESS_CHECKPOINT_REPLAYED" if bool(updated.get("idempotentReplay")) else "H7_PROGRESS_CHECKPOINT_WRITTEN",
        "stateMutated": not bool(updated.get("idempotentReplay")),
        "taskId": _compact(updated.get("taskId") or resolved_task, 160),
        "revision": int(updated.get("revision", revision) or revision),
        "transitionId": resolved_transition,
        "lastConfirmedSource": checkpoint["source"],
        "instructionAnchorBound": bool(normalized_instruction),
        "instructionMappingBound": bool(instruction_mapping),
        "canonicalStatusProjection": canonical_mutation_code,
        "projectProgress": {
            "state": str(((updated.get("projectProgressProof") or {}) if isinstance(updated.get("projectProgressProof"), dict) else {}).get("state", "withheld")),
            "payloadHash": str(((updated.get("projectProgressProof") or {}) if isinstance(updated.get("projectProgressProof"), dict) else {}).get("payloadHash", "")),
        },
        "phaseCloseout": {
            "state": "consumed" if phase_closeout_path is not None else "not_applicable",
            "code": phase_closeout_code,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        },
        "visibleProgress": {
            "state": "current",
            "source": str(((updated.get("visibleProgressReceipt") or {}) if isinstance(updated.get("visibleProgressReceipt"), dict) else {}).get("source", "")),
            "sentenceHash": str(((updated.get("visibleProgressReceipt") or {}) if isinstance(updated.get("visibleProgressReceipt"), dict) else {}).get("sentenceHash", "")),
            "payloadHash": str(((updated.get("visibleProgressReceipt") or {}) if isinstance(updated.get("visibleProgressReceipt"), dict) else {}).get("payloadHash", "")),
            "projectProgressPayloadHash": str(((updated.get("visibleProgressReceipt") or {}) if isinstance(updated.get("visibleProgressReceipt"), dict) else {}).get("projectProgressPayloadHash", "")),
        },
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "contractReadPath": contract_read_path,
    }


def dispatch_turn_close(
    package_root: str | Path,
    state_root: str | Path,
    *,
    task_id: str = "",
    workspace_key: str = "",
    session_key: str = "",
    turn_outcome: str = "unknown",
    user_control: str = "unknown",
    completion_evidence_ref: str = "",
    transition_id: str = "",
    project_root: str | Path | None = None,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Resolve and, if safe, execute one CAS-bound CloseTurn transition."""

    package = Path(package_root).expanduser().resolve()
    state = Path(state_root).expanduser().resolve()
    transaction_timeout = _authority_transaction_timeout(timeout)
    task = _compact(task_id, 160)
    root = _normalize_project_root(project_root)
    workspace = _normalize_workspace_key(workspace_key, base=root or package)
    session = _normalize_session_key(session_key)
    evidence = _compact(completion_evidence_ref, MAX_REFERENCE_CHARS)
    if not workspace or not session:
        policy = {
            "ok": True,
            "schema": "super-brain.continuation-policy.v1",
            "decision": "withhold_reconcile",
            "code": "CONTINUATION_POLICY_SCOPE_REQUIRED",
            "terminalReplyAllowed": True,
            "requiresParentResume": False,
            "branchStatus": "",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        return _base_result(policy=policy, resolution=None, code="TURN_CLOSE_DISPATCH_SCOPE_REQUIRED")

    if root is None:
        policy = {
            "ok": True,
            "schema": "super-brain.continuation-policy.v1",
            "decision": "withhold_reconcile",
            "code": "CONTINUATION_POLICY_PROJECT_ROOT_UNAVAILABLE",
            "terminalReplyAllowed": True,
            "requiresParentResume": False,
            "branchStatus": "",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        return _base_result(policy=policy, resolution=None, code="TURN_CLOSE_DISPATCH_PROJECT_ROOT_UNAVAILABLE")

    resolve_code, resolution = _invoke_contract(
        package,
        state,
        action="Resolve",
        task_id=task,
        workspace_key=workspace,
        session_key=session,
        timeout=transaction_timeout,
        execution_cwd=root,
    )
    if resolve_code != 0 or not isinstance(resolution, dict):
        policy = {
            "ok": True,
            "schema": "super-brain.continuation-policy.v1",
            "decision": "withhold_reconcile",
            "code": "CONTINUATION_POLICY_RESOLUTION_UNAVAILABLE",
            "terminalReplyAllowed": True,
            "requiresParentResume": False,
            "branchStatus": "",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        return _base_result(policy=policy, resolution=resolution, code="TURN_CLOSE_DISPATCH_RESOLUTION_UNAVAILABLE")

    stable_seed = "|".join((str(resolution.get("taskId") or task), workspace, session, str(turn_outcome), evidence))
    transition = _compact(transition_id, 120) or "turn-close-" + hashlib.sha256(stable_seed.encode("utf-8")).hexdigest()[:32]
    prior_receipts = resolution.get("transitionReceipts")
    if not isinstance(prior_receipts, list):
        # Resolve intentionally returns a compact packet.  Read the same
        # scoped contract once more only to inspect the bounded transition
        # ledger for an idempotent replay; no raw prompt or transcript is
        # opened or returned.
        get_code, full_contract = _invoke_contract(
            package,
            state,
            action="Get",
            task_id=_compact(resolution.get("taskId") or task, 160),
            workspace_key=workspace,
            session_key=session,
            timeout=transaction_timeout,
            execution_cwd=root,
        )
        if get_code == 0 and isinstance(full_contract, dict):
            prior_receipts = full_contract.get("transitionReceipts")
    if isinstance(prior_receipts, list):
        replay = next((item for item in prior_receipts if isinstance(item, dict) and str(item.get("transitionId", "")) == transition), None)
        # A close may carry a progress checkpoint in the same outer turn.  A
        # checkpoint is a normal ``Set`` transition, never evidence that a
        # parent was resumed.  Only a real ResumeParent ledger entry may be
        # replayed as a parent-return outcome.
        if replay and str(replay.get("action", "")) == "ResumeParent":
            result = _base_result(
                policy={
                    "ok": True,
                    "schema": "super-brain.continuation-policy.v1",
                    "decision": "resume_parent_required",
                    "code": "CONTINUATION_POLICY_RESUME_PARENT_REQUIRED",
                    "terminalReplyAllowed": False,
                    "requiresParentResume": True,
                    "branchStatus": "completed" if str(turn_outcome) == "side_branch_completed" else "partial",
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                },
                resolution=resolution,
                code="TURN_CLOSE_DISPATCH_IDEMPOTENT_REPLAY",
            )
            result["transition"] = _transition_summary(
                {
                    "ok": True,
                    "schema": "super-brain.execution-contract.v1",
                    "transitionAction": str(replay.get("action") or "ResumeParent"),
                    "replayedTransitionId": transition,
                    "originalResultRevision": replay.get("resultRevision", 0),
                    "taskId": resolution.get("taskId"),
                    "focusId": resolution.get("focusId"),
                    "focusLabel": resolution.get("focusLabel"),
                    "idempotentReplay": True,
                },
                transition_id=transition,
            )
            return result

    policy = decide_turn_close(
        resolution,
        turn_outcome=str(turn_outcome or "unknown"),
        user_control=str(user_control or "unknown"),
        completion_evidence_present=bool(evidence),
    )
    result = _base_result(policy=policy, resolution=resolution)
    if policy.get("decision") != "resume_parent_required":
        result["code"] = "TURN_CLOSE_DISPATCH_POLICY_ONLY"
        return result

    resolved_task = _compact(resolution.get("taskId") or task, 160)
    try:
        revision = int(resolution.get("contractRevision", 0) or 0)
    except (TypeError, ValueError):
        revision = 0
    fingerprint = _compact(resolution.get("planFingerprint"), 96)
    if not resolved_task or revision <= 0 or not fingerprint:
        result["code"] = "TURN_CLOSE_DISPATCH_CAS_FIELDS_MISSING"
        result["policy"] = {
            **policy,
            "decision": "withhold_reconcile",
            "code": "CONTINUATION_POLICY_CAS_FIELDS_MISSING",
            "terminalReplyAllowed": True,
            "requiresParentResume": False,
        }
        return result

    close_args = [
        "-TurnOutcome",
        str(turn_outcome),
        "-UserControl",
        str(user_control),
        "-CompletionEvidence",
        evidence,
        "-ExpectedRevision",
        str(revision),
        "-ExpectedPlanFingerprint",
        fingerprint,
        "-TransitionId",
        transition,
    ]
    close_args.extend(["-ProjectRoot", str(root)])
    close_code, closed = _invoke_contract(
        package,
        state,
        action="CloseTurn",
        task_id=resolved_task,
        workspace_key=workspace,
        session_key=session,
        timeout=transaction_timeout,
        extra=close_args,
        execution_cwd=root,
    )
    if close_code != 0 or not isinstance(closed, dict) or closed.get("ok") is not True:
        result["code"] = "TURN_CLOSE_DISPATCH_TRANSACTION_FAILED"
        result["contractCode"] = str((closed or {}).get("code", "")) if isinstance(closed, dict) else ""
        result["contractReason"] = _compact((closed or {}).get("reason", ""), 160) if isinstance(closed, dict) else ""
        result["policy"] = {
            **policy,
            "decision": "withhold_reconcile",
            "code": "CONTINUATION_POLICY_TRANSACTION_FAILED",
            "terminalReplyAllowed": True,
            "requiresParentResume": False,
        }
        result["transition"] = {"transitionId": transition, "action": "ResumeParent", "error": "transaction_failed", "rawPromptStored": False, "rawTranscriptStored": False}
        return result

    result["code"] = "TURN_CLOSE_DISPATCH_RESUMED_PARENT"
    result["stateMutated"] = not bool(closed.get("idempotentReplay"))
    result["transition"] = _transition_summary(closed, transition_id=transition)
    return result


__all__ = [
    "SCHEMA",
    "create_phase_closeout",
    "dispatch_turn_close",
    "find_phase_closeout_for_transition",
    "formal_phase_token",
    "is_formal_phase",
    "record_progress_checkpoint",
]
