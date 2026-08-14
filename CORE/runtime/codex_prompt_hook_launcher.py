from __future__ import annotations

"""Retired P7 launcher compatibility shim; H7 brain_turn owns lifecycle."""

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
