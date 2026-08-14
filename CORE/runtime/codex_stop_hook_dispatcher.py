from __future__ import annotations

"""Retired P7/Stop dispatcher compatibility shim; H7 brain_turn owns lifecycle."""

import json
import sys


def main() -> int:
    if "--describe" in sys.argv[1:]:
        sys.stdout.write(json.dumps({"ok": True, "state": "retired", "replacement": "H7 brain_turn"}, separators=(",", ":")))
    else:
        sys.stdout.write(json.dumps({}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
