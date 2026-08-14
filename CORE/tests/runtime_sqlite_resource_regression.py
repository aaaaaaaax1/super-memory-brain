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
sys.path.insert(0, str(ROOT / "runtime"))

from brain_core import BrainCore


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-sqlite-resource-") as directory:
        memory_root = Path(directory)
        scripts = memory_root / "scripts"
        scripts.mkdir(parents=True)
        for name in ("sandglass_paths.py", "sandglass_lock.py", "sandglass_vault.py", "sandglass_sqlite.py", "sandglass_log.py"):
            shutil.copy2(VENDOR / name, scripts / name)
        (memory_root / "sandglass.txt").write_text(
            "2026-07-18 09:00:00 | user | resource close regression marker\n",
            encoding="utf-8",
        )

        old_home = os.environ.get("NEXSANDBASE_HOME")
        os.environ["NEXSANDBASE_HOME"] = str(memory_root)
        sys.path.insert(0, str(scripts))
        try:
            module = importlib.import_module("sandglass_sqlite")
            assert module.sync_incremental() == 1
            for _ in range(20):
                assert module.search("resource close", limit=4)
                assert module.count() == 1
            sqlite_path = memory_root / "sandglass.db"
            log = importlib.import_module("sandglass_log")
            sys.modules["shadow_sand"] = types.SimpleNamespace(shadow_index=lambda text, line_num=0: None)
            assert log.log_message("[PROJECT][VERIFIED] writer freshness marker", sender="user")
            assert module.count() == 2
            assert module.search("writer freshness", limit=4)

            before = {
                path.name: (path.stat().st_size, path.stat().st_mtime_ns)
                for path in memory_root.glob("sandglass.db*")
            }
            core = BrainCore(ROOT, memory_root)
            rows = core._read_only_fts_rows("writer freshness", 4)
            after = {
                path.name: (path.stat().st_size, path.stat().st_mtime_ns)
                for path in memory_root.glob("sandglass.db*")
            }
            assert rows and rows[0][2] == "user"
            assert "writer freshness marker" in rows[0][3]
            assert after == before

            shutil.rmtree(memory_root)
            assert not sqlite_path.exists()
        finally:
            if old_home is None:
                os.environ.pop("NEXSANDBASE_HOME", None)
            else:
                os.environ["NEXSANDBASE_HOME"] = old_home
            sys.path.remove(str(scripts))
            sys.modules.pop("sandglass_sqlite", None)
            sys.modules.pop("sandglass_log", None)
            sys.modules.pop("shadow_sand", None)
            sys.modules.pop("sandglass_paths", None)
            sys.modules.pop("sandglass_lock", None)
            sys.modules.pop("sandglass_vault", None)

    print("RUNTIME_SQLITE_RESOURCE_REGRESSION_OK")


if __name__ == "__main__":
    main()
