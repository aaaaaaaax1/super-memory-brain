# Absorbed Capability Integration Invariant

Use this cold-path rule when adding or updating a skill source, plugin, MCP,
route, script capability, or capability metadata. Do not load it for ordinary
chat or simple task execution.

Default invariant: a source is not integrated merely because its files exist.
It becomes useful only after Super Brain absorbs it as a verified capability
with provenance, triggers, boundaries, route visibility, and regression
evidence. Do not install it as a standalone host skill unless the user gives
explicit approval for that exception.

Required closure:

1. Source and ownership
- Verify source path, upstream URL/commit, and license.
- Assign a stable capability ID and `executionOwner=super-memory-brain`.
- Retain the source as a cold provenance/parity reference; do not copy it into
  host skills or use it as the automatic execution path.

1.1 Native procedure and functional parity
- Before a source can be auto-routed, define a Super Brain-native procedure
  with an explicit ID, purpose, inputs, boundaries, stop condition, acceptance
  checks, and H7/authorization behavior.
- Map each verified source outcome to a native outcome. The native procedure
  must preserve every in-scope outcome or explicitly improve it; it may not
  silently narrow source functionality.
- Store the upstream source path only as provenance and comparison evidence.
  `sourcePath` is never the procedure automatically loaded or invoked for a
  user task.

2. Trigger and boundary
- Supply positive triggers, role, category, can-do, cannot-do, stop condition,
  and verification fields.
- Do not make a capability route merely because a user knows its old skill name.

3. Route visibility
- Build the absorbed-capability projection through `extension-capability-map.ps1`
  and merge it through `skill-capability-map.ps1`.
- Every non-trivial request must then pass through
  `absorbed-capability-route.ps1` after its operation intent is resolved.
  Selection is automatic from request semantics, source metadata, role,
  positive triggers, boundaries, and current task context; users must not need
  to remember or name the former skill.
- Return no more than four high-confidence compact cards. Ordinary greetings,
  simple concept answers, operational status/continuity requests, and
  low-confidence candidates must remain un-injected.
- A selected card must name the native procedure and its parity/acceptance
  evidence. It must not ask the user to invoke, install, or remember the
  upstream skill, nor cause the upstream `SKILL.md` to be auto-loaded.
- An upstream source marked user-only is not a standalone command dependency:
  translate its verified procedure into a Super Brain internal adapter. H7 is
  the sole continuity/handoff authority. Any retained procedure that could
  publish, label, comment, close, submit, or otherwise affect an external
  system remains proposal-only until the user approves the exact target and
  impact.
- Super Brain remains the only host-visible entry and execution owner.

4. Runtime order
- Preserve: H7 scope/contract → core rules → current project evidence → Super
  Brain route → bounded capability → verification → stage receipt.
- A capability must never override current user authorization, task state,
  latest visible instruction, privacy, or verification gates.
- When automatic capability selection participates, bind a compact,
  non-authorizing receipt/hash to H7. The receipt contains only selection,
  native-procedure, provenance/parity, and policy hashes; it must not carry the
  raw user prompt or transcript.

5. Cold-start boundary
- Never add ordinary capability details to AGENTS.md, CLAUDE.md, GEMINI.md, or
  the Super Brain startup block.
- Hot-refresh only the installed Super Brain core adapter after approval.

6. Regression and safety
- Add positive, negative, false-trigger, and source-to-native functional-parity
  checks; test capability routing, H7 receipt binding, and standalone-install
  absence.
- Preserve privacy and external-dependency boundaries. Security or reversing
  sources remain limited to authorized defensive, research, or CTF work.

7. Future inheritance
- This invariant and `SB-ABILITY-ABSORPTION-001` apply to all future skill
  intake. Only an explicit user instruction may request a standalone host skill
  instead of absorption.
