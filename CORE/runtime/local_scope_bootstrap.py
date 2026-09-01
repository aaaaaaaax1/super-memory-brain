"""Platform-neutral local scope bootstrap for a live Super Brain MCP channel.

The stdio MCP deliberately does not let a request, a Host id, or a model-visible
capability choose a workline.  This module receives only a local embedding
adapter's actual cwd and explicit random ``sid-*``.  It resolves that exact
current H7 contract and asks the Broker to *atomically* register it and open a
bound channel.  No pairing ref, channel selector, task selector, or workline
selector crosses this public boundary.
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

from brain_core import BrainCore
from scope_broker_ipc import ScopeBrokerClient
from scope_provider import LegacyEnvironmentScopeProvider


_SESSION_RE = re.compile(r"^sid-[a-f0-9]{16,64}$", re.IGNORECASE)
_LIFECYCLES = frozenset({"continue", "recover", "sync"})
_ACCESS_MODES = frozenset({"read", "write"})


def _canonical_hash(value: object) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _withheld(code: str, *, lifecycle: str) -> dict[str, Any]:
    return {
        "ok": False,
        "schema": "super-brain.local-scope-bootstrap.v1",
        "available": False,
        "state": "withheld",
        "code": code,
        "lifecycle": lifecycle,
        "scopeAuthorized": False,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _current_contract(
    core: BrainCore,
    *,
    workspace_key: str,
    owner_session_key: str,
) -> tuple[dict[str, Any] | None, str]:
    """Read exactly the caller's current contract and validate its identity."""

    try:
        contract, code = core._read_context_contract(workspace_key, owner_session_key)
    except (AttributeError, OSError, RuntimeError, ValueError):
        return None, "H7_SCOPE_BOOTSTRAP_CONTRACT_UNAVAILABLE"
    if not isinstance(contract, dict):
        # A new or unrelated local sid has no hot index by definition.  Both
        # representations mean the same public bootstrap condition: this
        # exact local scope has no current H7 contract.  Do not expose an
        # internal index topology distinction through a model-facing MCP
        # handshake.
        if str(code) in {"BRAIN_CONTEXT_NO_ACTIVE_CONTRACT", "BRAIN_CONTEXT_HOT_INDEX_MISSING"}:
            return None, "H7_SCOPE_BOOTSTRAP_CURRENT_CONTRACT_REQUIRED"
        return None, str(code or "H7_SCOPE_BOOTSTRAP_CONTRACT_UNAVAILABLE")
    if (
        contract.get("schema") != "super-brain.execution-contract.v1"
        or contract.get("status") != "active"
        or str(contract.get("workspaceKey", "")).lower() != workspace_key
        or str(contract.get("ownerSessionKey", "")).lower() != owner_session_key
        or not str(contract.get("taskId", "")).strip()
        or not re.fullmatch(r"ti-[a-f0-9]{16,64}", str(contract.get("taskInstanceId", "")), re.IGNORECASE)
        or not isinstance(contract.get("revision"), int)
        or isinstance(contract.get("revision"), bool)
        or int(contract.get("revision", 0)) < 1
        or str(contract.get("packageVersion", "")) != str(core.manifest.get("version", ""))
    ):
        return None, "H7_SCOPE_BOOTSTRAP_CONTRACT_INVALID"
    return contract, "H7_SCOPE_BOOTSTRAP_CONTRACT_CURRENT"


def bootstrap_local_mcp_channel(
    *,
    package_root: str | Path,
    memory_root: str | Path | None,
    workspace_root: str | Path,
    local_session: str,
    lifecycle: str = "continue",
    access_mode: str = "write",
    broker_client: ScopeBrokerClient | None = None,
) -> tuple[dict[str, Any], str]:
    """Bind a new private MCP channel from one exact local H7 contract.

    The caller must already have created the H7 contract through the normal
    governed lifecycle. A missing contract is intentionally not converted into
    a synthetic task. The returned channel id is private process plumbing for
    ``brain_mcp``; it is never included in the public result and must never be
    returned from an MCP tool or CLI response.
    """

    normalized_lifecycle = str(lifecycle or "").strip().lower()
    if normalized_lifecycle not in _LIFECYCLES:
        return _withheld("H7_SCOPE_BOOTSTRAP_LIFECYCLE_INVALID", lifecycle=normalized_lifecycle), ""
    normalized_mode = str(access_mode or "").strip().lower()
    if normalized_mode not in _ACCESS_MODES:
        return _withheld("H7_SCOPE_BOOTSTRAP_ACCESS_MODE_INVALID", lifecycle=normalized_lifecycle), ""
    normalized_session = str(local_session or "").strip().lower()
    if not _SESSION_RE.fullmatch(normalized_session):
        return _withheld("H7_SCOPE_BOOTSTRAP_LOCAL_SESSION_REQUIRED", lifecycle=normalized_lifecycle), ""
    try:
        project_root = Path(workspace_root).expanduser().resolve()
    except (OSError, RuntimeError, ValueError):
        return _withheld("H7_SCOPE_BOOTSTRAP_WORKSPACE_INVALID", lifecycle=normalized_lifecycle), ""
    if not project_root.is_dir():
        return _withheld("H7_SCOPE_BOOTSTRAP_WORKSPACE_INVALID", lifecycle=normalized_lifecycle), ""

    # Do not read the process-wide workspace override.  The caller supplied a
    # real local cwd/root for this one operation, so deriving another scope
    # from an ambient variable would recreate a selector bypass.
    provider = LegacyEnvironmentScopeProvider(
        cwd_reader=lambda: str(project_root),
        session_reader=lambda: normalized_session,
    )
    core = BrainCore(package_root, memory_root, scope_provider=provider)
    resolution = provider.resolve(write=True)
    if not resolution.current or not resolution.workspace_key or not resolution.owner_session_key:
        return _withheld(str(resolution.code or "H7_SCOPE_BOOTSTRAP_LOCAL_SCOPE_REQUIRED"), lifecycle=normalized_lifecycle), ""
    contract, contract_code = _current_contract(
        core,
        workspace_key=resolution.workspace_key,
        owner_session_key=resolution.owner_session_key,
    )
    if contract is None:
        return _withheld(contract_code, lifecycle=normalized_lifecycle), ""

    # The MCP entrypoint may already own a broker client whose auto-started
    # child must be shut down with the served channel. Reuse that client when
    # supplied so broker process ownership cannot be lost between bootstrap
    # and MCP teardown. Standalone callers retain the self-contained client
    # lifecycle below.
    control = broker_client if broker_client is not None else ScopeBrokerClient(
        core.memory_base,
        auto_start=True,
        runtime_path=Path(__file__).with_name("scope_broker_ipc.py"),
    )
    owns_control = broker_client is None
    channel_id = ""
    try:
        bound = control.bootstrap_bound_channel(
            contract,
            expected_contract_hash=_canonical_hash(contract),
            project_root=project_root,
            access_mode=normalized_mode,
        )
        channel_id = str(bound.get("channelId", ""))
        if bound.get("ok") is not True:
            return _withheld(str(bound.get("code", "H7_SCOPE_BOOTSTRAP_BIND_FAILED")), lifecycle=normalized_lifecycle), ""
        if not re.fullmatch(r"sbc-[a-f0-9]{32}", channel_id, re.IGNORECASE):
            return _withheld("H7_SCOPE_BOOTSTRAP_CHANNEL_INVALID", lifecycle=normalized_lifecycle), ""
        # Do not expose the private channel id, lease, workline id, local
        # path, session id, or contract fingerprint. The caller receives the
        # id only through this private return channel; model-visible MCP sees
        # the public boolean result below.
        return {
            "ok": True,
            "schema": "super-brain.local-scope-bootstrap.v1",
            "available": True,
            "state": "current",
            "code": "H7_SCOPE_BOOTSTRAP_BOUND",
            "lifecycle": normalized_lifecycle,
            "scopeAuthorized": True,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }, channel_id
    except (OSError, RuntimeError, TypeError, ValueError):
        return _withheld("H7_SCOPE_BOOTSTRAP_CONTROL_UNAVAILABLE", lifecycle=normalized_lifecycle), ""
    finally:
        if owns_control:
            # Standalone callers receive only the public projection; the
            # private channel is not transferable across this function's
            # lifetime. Close it before releasing the client so a failed or
            # successful bootstrap cannot leave a bound lease in the Broker.
            if channel_id:
                try:
                    control.close_channel(channel_id, allow_auto_start=False)
                except Exception:
                    pass
            try:
                control.close()
            except Exception:
                pass


def bootstrap_local_scope(
    *,
    package_root: str | Path,
    memory_root: str | Path | None,
    workspace_root: str | Path,
    local_session: str,
    lifecycle: str = "continue",
    access_mode: str = "write",
) -> dict[str, Any]:
    """Return only the public result of an atomic local MCP bootstrap."""

    result, _ = bootstrap_local_mcp_channel(
        package_root=package_root,
        memory_root=memory_root,
        workspace_root=workspace_root,
        local_session=local_session,
        lifecycle=lifecycle,
        access_mode=access_mode,
    )
    return result


__all__ = ["bootstrap_local_scope", "bootstrap_local_mcp_channel"]
