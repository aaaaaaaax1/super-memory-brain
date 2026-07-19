import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "vendor" / "NexSandglass-Agent-DedicatedMemory"


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-index-regression-") as directory:
        memory_root = Path(directory)
        scripts = memory_root / "scripts"
        scripts.mkdir(parents=True)
        for name in ("sandglass_paths.py", "sandglass_lock.py", "sandglass_vault.py"):
            shutil.copy2(VENDOR / name, scripts / name)
        lines = [
            f"2026-07-17 09:00:{index:02d} | user | stable index record {index} concurrency marker"
            for index in range(1, 121)
        ]
        (memory_root / "sandglass.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        writer = (
            "import os, sys; "
            "sys.path.insert(0, os.path.join(os.environ['NEXSANDBASE_HOME'], 'scripts')); "
            "import sandglass_vault; failures = 0; "
            "\nfor _ in range(24): failures += int(sandglass_vault.rebuild_index() < 0); "
            "print(failures)"
        )
        reader = (
            "import os, sys; "
            "sys.path.insert(0, os.path.join(os.environ['NEXSANDBASE_HOME'], 'scripts')); "
            "import sandglass_vault; failures = 0; "
            "\nfor _ in range(80): "
            " sandglass_vault._idx_cache = None; "
            " failures += int(not sandglass_vault._sync_index()); "
            "\nprint(failures)"
        )
        environment = dict(os.environ)
        environment["NEXSANDBASE_HOME"] = str(memory_root)
        subprocess.run(
            [sys.executable, "-c", writer.replace("range(24)", "range(1)")],
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )
        writer_count = 4
        reader_count = 8
        processes = [
            subprocess.Popen(
                [sys.executable, "-c", writer if index < writer_count else reader],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for index in range(writer_count + reader_count)
        ]
        outputs = [process.communicate(timeout=60) for process in processes]
        failed_calls = sum(
            int(line)
            for stdout, _ in outputs
            for line in stdout.splitlines()
            if line.strip()
        )
        stderr_count = sum(bool(stderr.strip()) for _, stderr in outputs)
        index_path = memory_root / "sandglass.idx"
        temporary_files = list(memory_root.glob("sandglass.idx.*.tmp"))
        result = {
            "ok": failed_calls == 0 and stderr_count == 0 and index_path.exists() and not temporary_files,
            "workers": len(processes),
            "writerWorkers": writer_count,
            "readerWorkers": reader_count,
            "writerRounds": 24,
            "readerRounds": 80,
            "attempts": writer_count * 24 + reader_count * 80,
            "failedCalls": failed_calls,
            "stderrCount": stderr_count,
            "temporaryFileCount": len(temporary_files),
            "indexBytes": index_path.stat().st_size if index_path.exists() else 0,
        }
        print(json.dumps(result, ensure_ascii=False))
        if not result["ok"]:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
