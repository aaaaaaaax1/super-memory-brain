from __future__ import annotations

"""Keep source verification independent from installed-entry verification."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    text = (ROOT / "scripts" / "verify-package.ps1").read_text(encoding="utf-8")
    source_branch = text.split("function ConvertTo-VerifyPackageArgument", 1)[0]
    assert "[switch]$PackageOnly" in text
    assert "if ($PackageOnly -and -not $Worker)" in source_branch
    assert "super-brain.verify-package-source-result.v1" in source_branch
    assert "scope='package_source_only'" in source_branch
    assert "deploymentChecked=$false" in source_branch
    assert "wrotePackageStatus=$false" in source_branch
    assert "skill-sync-check.ps1" not in source_branch
    assert "startup-check.ps1" not in source_branch
    assert "memory-eval.ps1 -Json" in source_branch
    assert "memory\\workspace\\procedure-cards" not in text
    assert "memory/workspace/procedure-cards" not in text
    assert "public procedure contract support" in text
    print("runtime verify-package layers regression: passed (1/1)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
