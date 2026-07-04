# Extension Integration Invariant

Use this cold-path rule when adding or updating any skill, extension, plugin,
MCP, route, script capability, or capability metadata. Do not load it for
ordinary chat or simple task execution.

Default invariant: file presence is not integration. A capability is complete
only when package source, trigger metadata, ability maps, routing visibility,
installed-state expectations, regression evidence, and rollback evidence are all
accounted for, unless the user explicitly scopes the work to a temporary file
only.

Required closure:

1. Source and installed state
- Confirm package source exists.
- State whether installed copies are required.
- Keep package source paths and installed skill paths distinct.

2. Trigger entry
- SKILL.md description, triggers, or when-to-use metadata must be discoverable.
- Include positive triggers and negative boundaries.
- Do not rely on the user naming a file path as the only discovery mechanism.

3. Ability and route visibility
- Enter the appropriate layer: extension-capability-map, skill-capability-map,
  route-map, or capabilities metadata.
- If a layer is intentionally skipped, record why.
- Do not mark work complete while ORC or the ability map cannot see it.

4. Cold-start boundary
- Do not put normal domain extensions into AGENTS.md, CLAUDE.md, GEMINI.md, or
  the Super Brain hot path.
- Reserve cold-start entries for global hard routes such as Super Brain entry,
  memory:auto, G1/ORC/Sandglass, Agent Bridge, or browser-act.
- Rewriting global startup files requires explicit user approval.

5. Hot-start discovery
- Confirm host-visible installed metadata when installed sync is in scope.
- Use narrow hot-refresh only after approval; never default to AllKnown or broad
  refresh.
- If not refreshed, report source/installed hash differences clearly.

6. Regression protection
- Add or cite positive cases, negative cases, and false-trigger protection.
- Route changes need route regression cases.
- Script, manifest, and ability-map changes need Pester or a lightweight static
  or query check.
- Strict gates must not regress.

7. Synchronization verification
- Check package source hash and installed hash when applicable.
- Check Codex and ZCode installed copies separately.
- Do not modify plusunm-g1, nexsandglass-dedicated-memory, AGENTS.md, or
  unrelated skills unless separately approved.

8. Safety, privacy, and external dependencies
- Never store secrets, raw transcripts, payloads, or sample details as durable
  memory or public evidence.
- Document external repositories, MCPs, network, GUI/device tools, and setup
  requirements.
- Security and reverse-engineering capabilities must stay in authorized, CTF, or
  defensive research contexts and must not support malicious evasion,
  destructive actions, DoS, credential theft, or mass abuse.

9. Rollback and evidence
- Create a rollback path before writes.
- Report modified files and sensitive files not modified.
- Report whether hot-refresh, release, publish, or share was executed.
- Save before/after hashes or an evidence report.

10. Inheritance
- This invariant applies to future capability additions by default.
- A user must explicitly say when a change is only a temporary file drop and does
  not require ability-map, route, sync, or regression integration.

ReverseLab example: ReverseLab is a domain extension, so it must be discoverable
through skill/extension metadata and capability maps, but must not be added to
global cold-start bootstrap or the Super Brain hot path.
