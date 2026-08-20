from __future__ import annotations

import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "runtime"))

import activation_receipt


def main() -> int:
    source = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="super-brain-activation-identity-") as raw:
        package = Path(raw) / "package"
        package.mkdir()
        for name in ("manifest.json", "route-map.json", "capabilities.json", "super-brain-rules.json"):
            shutil.copyfile(source / name, package / name)

        activation_receipt._STATIC_IDENTITY_CACHE.clear()
        read_count = {"json": 0, "hash": 0}
        original_read_json = activation_receipt._read_json
        original_file_sha256 = activation_receipt.file_sha256

        def counted_read_json(path: Path):
            read_count["json"] += 1
            return original_read_json(path)

        def counted_file_sha256(path: Path):
            read_count["hash"] += 1
            return original_file_sha256(path)

        activation_receipt._read_json = counted_read_json
        activation_receipt.file_sha256 = counted_file_sha256
        try:
            first = activation_receipt._static_identity(package)
            first_counts = dict(read_count)
            second = activation_receipt._static_identity(package)
            assert second is first
            assert read_count == first_counts, (first_counts, read_count)

            route_path = package / "route-map.json"
            route = json.loads(route_path.read_text(encoding="utf-8"))
            route["routes"] = list(route.get("routes", []))
            route["routes"].append({"id": "identity-regression-route"})
            route_path.write_text(json.dumps(route, ensure_ascii=False), encoding="utf-8")
            changed = activation_receipt._static_identity(package)
            assert changed is not second
            assert changed["routeMapHash"] != first["routeMapHash"]
            assert read_count["json"] > first_counts["json"]
            assert read_count["hash"] > first_counts["hash"]

            (package / "capabilities.json").unlink()
            missing = activation_receipt._static_identity(package)
            assert missing["capabilitiesReady"] is False
            assert missing["capabilitiesHash"] == ""
            # A missing input is not cached; repair must be observed next call.
            missing_counts = dict(read_count)
            activation_receipt._static_identity(package)
            assert read_count["json"] > missing_counts["json"]
        finally:
            activation_receipt._read_json = original_read_json
            activation_receipt.file_sha256 = original_file_sha256
            activation_receipt._STATIC_IDENTITY_CACHE.clear()
    print("runtime_activation_static_identity_regression: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
