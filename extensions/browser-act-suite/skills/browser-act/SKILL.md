---
name: browser-act
description: "Fallback browser automation via browser-act. Use only when explicitly requested or Playwright cannot reliably complete the operation, especially visible verification controls, browser-act session/state, or HAR capture. Load before running browser-act."
allowed-tools: Bash(browser-act:*)
metadata:
  author: BrowserAct
  version: "2.0.2"
  install: "uv tool install browser-act-cli --python 3.12"
  homepage: "https://www.browseract.com"
  requires:
    runtime: "Python 3.12+, uv package manager"
  permissions:
    - "Network access — required for: CLI install from PyPI; optional verification-assistance API (sends only the challenge image, no cookies or page content)"
    - "Filesystem read/write at CLI data directory — browser profiles (per-browser isolated) and session logs (rotated each run)"
    - "CDP connection to local Chrome — chrome-direct type only, requires explicit user confirmation"
  data-privacy:
    local-only: "All cookies, login sessions, page content, credentials, and browser profile data are stored and processed locally — never uploaded. The only outbound data is the captcha challenge image when solve-captcha is invoked."
  user-confirmation-required:
    - "First-time install (uv tool install): downloads external package"
    - "Browser creation: requires explicit user approval"
    - "Sensitive operations: login, form submission, file upload require user confirmation"
---

# browser-act

Browser automation CLI for AI agents. Runs a full browser engine: navigation &
interaction, data extraction & network capture, screenshots, form automation,
multi-browser parallel operation, user-configured proxy support, and
human-agent collaboration.

### Features

- Lightweight extraction — fast JS-rendered content fetch without opening a browser session, advanced WebFetch/curl replacement
- Session management — multi-browser isolation, multi-account parallel operation
- Verification assistance — when automation encounters interactive challenges, assists completion with user authorization
- Complex interaction — DOM content extraction, screenshots, form filling, file upload
- Human-agent collaboration — headed mode + remote assist for manual steps
- Safety controls — Confirmation Gate protocol requires explicit user approval before browser creation, deletion, and sensitive operations
- Universal compatibility — works with Cursor, Claude Code, Codex, Windsurf, etc.

Install: `uv tool install browser-act-cli --python 3.12`


## CLI entrypoint

`browser-act` is a CLI skill, not necessarily a separately exposed MCP/tool button. If no direct `browser-act` tool appears in the current host tool list, that does not mean browser-act is unavailable.

Lookup order for this Windows install:

```powershell
browser-act get-skills core --skill-version 2.0.2
& "<user-home>\AppData\Roaming\Python\Python312\Scripts\browser-act.exe" get-skills core --skill-version 2.0.2
```

Use Playwright for normal browser automation. Use the CLI entrypoint below only
after the browser-act fallback route has been selected because the user asked
for it or Playwright could not reliably complete the operation.
## Start here

Before running any `browser-act` command, load the usage guide from the CLI:

```bash
browser-act get-skills core --skill-version 2.0.2   # start here — workflows, common patterns, troubleshooting
```

**Do NOT skip this step regardless of how simple the command seems.**

**Do NOT truncate the output** — it contains operational directives and
environment state that are critical for correct operation. Truncating will
cause you to miss browser selection rules and safety constraints.

`get-skills core` provides environment status, available browsers, operational
directives, and the complete interaction workflow — none of which are available
through `--help`.


