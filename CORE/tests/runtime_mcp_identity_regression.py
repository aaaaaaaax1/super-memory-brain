from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
import sys

sys.path.insert(0, str(ROOT / "runtime"))

from brain_core import _mcp_runtime_identity, _mcp_runtime_identity_paths
import mcp_runtime_identity
from mcp_runtime_identity import runtime_identity


def _powershell_identity(package_root: Path) -> str:
    command = (
        ". (Join-Path $env:SB_TEST_PACKAGE_ROOT 'scripts\\common.ps1'); "
        "Get-SuperBrainMcpRuntimeIdentity $env:SB_TEST_PACKAGE_ROOT"
    )
    env = dict(os.environ)
    env["SB_TEST_PACKAGE_ROOT"] = str(package_root)
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
        cwd=ROOT.parent,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    return result.stdout.strip().splitlines()[-1]


def test_import_closure_is_complete_and_cross_transport() -> None:
    manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
    paths = _mcp_runtime_identity_paths(ROOT)
    assert paths
    assert len(paths) == len(set(paths))
    assert all(not path.startswith(("/", "\\")) for path in paths)
    assert all(".." not in path.split("/") for path in paths)
    assert "runtime/brain_mcp.py" in paths
    for required in (
        "runtime/activation_receipt.py",
        "runtime/brain_control.py",
        "runtime/brain_context.py",
        "runtime/continuation_policy.py",
        "runtime/layout_paths.py",
        "runtime/migration_control.py",
        "runtime/turn_close_dispatcher.py",
        "runtime/turn_intent.py",
    ):
        assert required in paths, required
    assert all((ROOT / path).is_file() for path in paths)

    python_identity = _mcp_runtime_identity(ROOT)
    powershell_identity = _powershell_identity(ROOT)
    assert python_identity and python_identity == powershell_identity


def test_invalid_identity_manifests_fail_closed() -> None:
    invalid_manifests = [
        {"version": "0.0.0", "mcpRuntimeIdentityRoots": ["runtime/brain_mcp.py", "../outside.py"], "mcpRuntimeIdentityAssets": ["super-brain-rules.json"]},
        {"version": "0.0.0", "mcpRuntimeIdentityRoots": ["runtime/brain_mcp.py", "runtime/brain_mcp.py"], "mcpRuntimeIdentityAssets": ["super-brain-rules.json"]},
        {"version": "0.0.0", "mcpRuntimeIdentityRoots": ["runtime//brain_mcp.py"], "mcpRuntimeIdentityAssets": ["super-brain-rules.json"]},
        {"version": "0.0.0", "mcpRuntimeIdentityRoots": ["C:/outside.py"], "mcpRuntimeIdentityAssets": ["super-brain-rules.json"]},
    ]
    for manifest in invalid_manifests:
        with tempfile.TemporaryDirectory(prefix="super-brain-identity-invalid-") as directory:
            package = Path(directory)
            (package / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            assert _mcp_runtime_identity_paths(package) == ()

    with tempfile.TemporaryDirectory(prefix="super-brain-identity-invalid-") as directory:
        package = Path(directory)
        (package / "manifest.json").write_text(
            json.dumps({"version": "0.0.0", "mcpRuntimeIdentityRoots": ["../outside.py"], "mcpRuntimeIdentityAssets": ["super-brain-rules.json"]}),
            encoding="utf-8",
        )
        command = (
            ". (Join-Path $env:SB_TEST_COMMON_ROOT 'common.ps1'); "
            "try { Get-SuperBrainMcpRuntimeIdentity $env:SB_TEST_PACKAGE_ROOT; exit 0 } "
            "catch { exit 7 }"
        )
        env = dict(os.environ)
        env["SB_TEST_PACKAGE_ROOT"] = str(package)
        env["SB_TEST_COMMON_ROOT"] = str(ROOT / "scripts")
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
            cwd=ROOT.parent,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 7, result.stdout + result.stderr


def test_identity_cache_is_process_local_only() -> None:
    # Exercise the first cold identity compilation while legacy persistence
    # environment variables are present. Earlier tests intentionally warm the
    # same package path, which would otherwise prove only the hot-cache path.
    mcp_runtime_identity._IDENTITY_CACHE.clear()
    with tempfile.TemporaryDirectory(prefix="super-brain-identity-no-persist-") as directory:
        cache_root = Path(directory)
        previous = os.environ.get("SUPER_BRAIN_PERSIST_IDENTITY_CACHE")
        previous_home = os.environ.get("NEXSANDBASE_HOME")
        os.environ["SUPER_BRAIN_PERSIST_IDENTITY_CACHE"] = "1"
        os.environ["NEXSANDBASE_HOME"] = str(cache_root)
        try:
            first = runtime_identity(ROOT)
            second = runtime_identity(ROOT)
            assert first and first == second
            assert not any(cache_root.iterdir())
            assert not hasattr(mcp_runtime_identity, "_persistent_cache_path")
        finally:
            if previous is None:
                os.environ.pop("SUPER_BRAIN_PERSIST_IDENTITY_CACHE", None)
            else:
                os.environ["SUPER_BRAIN_PERSIST_IDENTITY_CACHE"] = previous
            if previous_home is None:
                os.environ.pop("NEXSANDBASE_HOME", None)
            else:
                os.environ["NEXSANDBASE_HOME"] = previous_home


def main() -> None:
    test_import_closure_is_complete_and_cross_transport()
    test_invalid_identity_manifests_fail_closed()
    test_identity_cache_is_process_local_only()
    print("runtime_mcp_identity_regression: PASS")


if __name__ == "__main__":
    main()
