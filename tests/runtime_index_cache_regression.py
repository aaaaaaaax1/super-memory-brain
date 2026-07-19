from __future__ import annotations

import importlib
import os
import shutil
import sys
import tempfile
import types
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "vendor" / "NexSandglass-Agent-DedicatedMemory"


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-index-cache-") as directory:
        memory_root = Path(directory)
        scripts = memory_root / "scripts"
        scripts.mkdir(parents=True)
        for name in ("sandglass_paths.py", "sandglass_lock.py", "sandglass_vault.py", "sandglass_think.py"):
            shutil.copy2(VENDOR / name, scripts / name)
        (memory_root / "sandglass.txt").write_text(
            "2026-07-18 09:00:00 | user | stable cache marker for index reuse\n",
            encoding="utf-8",
        )

        old_home = os.environ.get("NEXSANDBASE_HOME")
        os.environ["NEXSANDBASE_HOME"] = str(memory_root)
        sys.path.insert(0, str(scripts))
        try:
            vault = importlib.import_module("sandglass_vault")
            density = types.ModuleType("sandglass_think")
            density._tokenize_for_density = vault._tokenize
            sys.modules["sandglass_think"] = density
            rebuilds = {"count": 0}
            original = vault.rebuild_index

            def counted_rebuild() -> int:
                rebuilds["count"] += 1
                return original()

            vault.rebuild_index = counted_rebuild
            assert vault.idx_search("stable cache", limit=2)
            first_rebuild_count = rebuilds["count"]
            assert vault.idx_search("stable cache", limit=2)
            assert rebuilds["count"] == first_rebuild_count, rebuilds
        finally:
            if old_home is None:
                os.environ.pop("NEXSANDBASE_HOME", None)
            else:
                os.environ["NEXSANDBASE_HOME"] = old_home
            sys.path.remove(str(scripts))
            for name in ("sandglass_vault", "sandglass_paths", "sandglass_lock", "sandglass_think"):
                sys.modules.pop(name, None)

    print("RUNTIME_INDEX_CACHE_REGRESSION_OK")


if __name__ == "__main__":
    main()
