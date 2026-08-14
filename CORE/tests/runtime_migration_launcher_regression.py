from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "scripts" / "migrate-memory-layout.ps1"


def invoke(source: Path, state_root: Path, action: str, *, apply: bool = False, epoch_id: str = "") -> tuple[subprocess.CompletedProcess[str], dict[str, object] | None]:
    arguments = [
        "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(LAUNCHER),
        "-Action", action, "-ImportRoot", str(source), "-StateRoot", str(state_root), "-Json",
    ]
    if epoch_id:
        arguments.extend(["-EpochId", epoch_id])
    if apply:
        arguments.append("-Apply")
    completed = subprocess.run(arguments, capture_output=True, text=True, check=False)
    value = json.loads(completed.stdout) if completed.returncode == 0 and completed.stdout.strip() else None
    return completed, value


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-migration-launcher-") as directory:
        root = Path(directory)
        source = root / "legacy-source"
        source.mkdir(parents=True)
        (source / "memory.md").write_text("Launcher imports only through the staged migration control plane.", encoding="utf-8")
        state_root = root / "private-state"
        epoch_id = "migration-launcher-001"

        planned_process, planned = invoke(source, state_root, "Plan")
        assert planned_process.returncode == 0 and planned is not None
        assert planned["plannedCount"] == 1
        staged_process, staged = invoke(source, state_root, "Stage", apply=True, epoch_id=epoch_id)
        assert staged_process.returncode == 0 and staged is not None and staged["status"] == "staged"
        imported_process, imported = invoke(source, state_root, "Import", apply=True, epoch_id=epoch_id)
        assert imported_process.returncode == 0 and imported is not None and imported["recordCounts"]["imported"] == 1
        verified_process, verified = invoke(source, state_root, "Verify", apply=True, epoch_id=epoch_id)
        assert verified_process.returncode == 0 and verified is not None and verified["ok"] is True
        cutover_process, cutover = invoke(source, state_root, "Cutover", apply=True, epoch_id=epoch_id)
        assert cutover_process.returncode == 0 and cutover is not None and cutover["status"] == "cutover"
        cleanup_process = subprocess.run(
            [
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(LAUNCHER),
                "-Action", "Plan", "-ImportRoot", str(source), "-StateRoot", str(state_root), "-CleanupImport", "-Json",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        assert cleanup_process.returncode != 0
        assert (source / "memory.md").is_file(), "cleanup must never delete an import root implicitly"
    print("RUNTIME_MIGRATION_LAUNCHER_REGRESSION_OK")


if __name__ == "__main__":
    main()
