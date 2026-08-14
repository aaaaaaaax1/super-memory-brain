from __future__ import annotations

"""Retired P7/UserPromptSubmit compatibility shim.

H7 ``brain_turn`` is the only Super Brain lifecycle authority. This module
keeps a stale cached native handler harmless: it emits a valid empty hook
response, reads no prompt, and writes no state.
"""

import json
import sys


def main() -> int:
    sys.stdout.write(
        json.dumps(
            {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ""}},
            ensure_ascii=False,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
