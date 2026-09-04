# Host-neutral local MCP adapter

`runtime/local_scope_adapter.py` is the package-owned launch contract for a
real local Super Brain MCP process. It keeps the Super Brain control plane
independent of Codex, an app server, or any other host.

## Scope contract

An embedding host supplies the prepared local memory root plus exactly two
scope facts when it starts one launcher process:

1. the target project root as the process working directory; and
2. a fresh or same-workline `SUPER_BRAIN_LOCAL_SESSION_ID` in the strict form
   `sid-` followed by 16–64 hexadecimal characters.

The SID is placed only in the child environment. It is not an argv value, MCP
argument, request field, config entry, log message, or visible receipt. The
adapter copies only the bounded interpreter/OS environment allowlist; Host or
Codex identifiers and selector-like variables are discarded.

The adapter starts:

```text
python -X utf8 -B CORE/runtime/local_mcp_launcher.py \
  --package-root <package-root> \
  --memory-root <memory-root>
```

The launcher consumes the SID before serving MCP. H7 then resolves the
current local contract and project proof and performs the atomic Broker bind.
The adapter does not select a task, workline, contract, channel, pairing ref,
or workspace key.

The bootstrap IPC carries a private one-time operation token. If the response
is lost after the Broker commits a channel, the client cancels that exact
operation without sending a channel or workline selector; if the client also
disappears, the Broker reaps the pending operation after a bounded grace
period. Lease expiry/reclamation continues even when Broker process idle
shutdown is disabled.

`memory_root` is required and must already be a local directory. Omitting it
is rejected rather than falling back to a package default or ambient
environment-derived state root.

## Lifecycle

Use `generate_session_id()` for a new local session and reuse the same value
when restarting the same workline. A changed workspace, SID, or Broker
instance requires a new launcher process; do not mutate a running process or
add a scope selector to an MCP request. A newly generated SID is a new local
session and must use the explicit H7 local-rebind issue → consume → finalize
flow when it is intended to continue an existing workline.

`launch(spec)` returns the adapter-owned `subprocess.Popen` instance. Close it
by sending EOF with `close_process(process)`; the helper waits after terminate
and kill so a Windows Broker lock is not left behind during cleanup.

`verify_startup(initialize_response)` is a non-authorizing health check. It is
true only when the initialize handshake reports
`H7_SCOPE_BOOTSTRAP_BOUND`, a bound scope, and `scopeReady=true`. The result
must not be cached as permission for a later process or scope.

## Static registration

The installed static launcher intentionally starts without a SID. Its expected
result is `H7_SCOPE_INJECTION_LOCAL_SESSION_REQUIRED`, `withheld`, and no
Broker channel. This discovery/health path must remain inert; a host that
needs governed work must use the adapter contract above.

## Minimal Python example

```python
from local_scope_adapter import build_launch_spec, close_process, generate_session_id, launch

session_id = generate_session_id()
spec = build_launch_spec(package_root, memory_root, project_root, session_id)
process = launch(spec)
try:
    # Send JSON-RPC initialize and verify_startup(response) here.
    ...
finally:
    close_process(process)
```

The legacy CLI provider intentionally retains its historical compatibility
normalization. It is not the host-neutral MCP adapter and must not be used to
derive a static MCP scope.
