from __future__ import annotations

"""Retired P7/Stop compatibility shim; H7 brain_turn owns lifecycle."""

import json
import sys


def main() -> int:
    # An empty decision is the host's allow/no-op response. No input is read
    # and no continuation state, telemetry, or memory is written.
    sys.stdout.write(json.dumps({}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
