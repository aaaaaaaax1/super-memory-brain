from __future__ import annotations

import hashlib
import shutil
import sys
import tempfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "runtime"))

import activation_receipt


STATIC_JSON_NAMES = ("manifest.json", "route-map.json", "capabilities.json")
STATIC_IDENTITY_NAMES = (*STATIC_JSON_NAMES, "super-brain-rules.json")


def main() -> int:
    source = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="super-brain-activation-identity-") as raw:
        package = Path(raw) / "package"
        package.mkdir()
        for name in STATIC_IDENTITY_NAMES:
            shutil.copyfile(source / name, package / name)

        activation_receipt._STATIC_IDENTITY_CACHE.clear()
        target_paths = {str((package / name).resolve()) for name in STATIC_JSON_NAMES}
        reads: dict[str, int] = {}
        original_read_bytes = Path.read_bytes

        def counted_read_bytes(path: Path) -> bytes:
            key = str(path.resolve())
            reads[key] = reads.get(key, 0) + 1
            return original_read_bytes(path)

        # A cold compilation reads each JSON input once; parsing and hashing
        # must derive from that same byte sequence.
        with mock.patch.object(Path, "read_bytes", new=counted_read_bytes):
            first = activation_receipt._static_identity(package)
            first_reads = dict(reads)
            second = activation_receipt._static_identity(package)

        assert second is first
        assert reads == first_reads, (first_reads, reads)
        assert {path: reads.get(path, 0) for path in target_paths} == {
            path: 1 for path in target_paths
        }, reads
        assert first["manifestHash"] == hashlib.sha256(
            (package / "manifest.json").read_bytes()
        ).hexdigest()
        assert first["routeMapHash"] == hashlib.sha256(
            (package / "route-map.json").read_bytes()
        ).hexdigest()
        assert first["capabilitiesHash"] == hashlib.sha256(
            (package / "capabilities.json").read_bytes()
        ).hexdigest()

        # Activation currentness must bind the capability map bytes as well as
        # the manifest and route map.  A valid-but-replaced capability map may
        # keep the same shape while changing the route surface, so it must
        # force a fresh activation receipt rather than being silently reused.
        memory_base = Path(raw) / "memory"
        memory_base.mkdir()
        activated = activation_receipt.activate(
            package,
            memory_base,
            workspace_key="ws-capabilities-currentness",
            session_key="sid-capabilities-currentness",
            route="bare_wake",
        )
        assert activated["package"]["capabilitiesHash"] == first["capabilitiesHash"]
        capabilities_path = package / "capabilities.json"
        capabilities_path.write_bytes(capabilities_path.read_bytes() + b" ")
        current, current_code = activation_receipt.read_valid(
            memory_base,
            workspace_key="ws-capabilities-currentness",
            session_key="sid-capabilities-currentness",
            package_root=package,
        )
        assert current is None, current
        assert current_code == "ACTIVATION_RECEIPT_CAPABILITIES_STALE", current_code

        # A malformed UTF-8-sig JSON document remains fail-closed, but its
        # receipt staleness hash remains the SHA-256 of its exact raw bytes.
        route_path = package / "route-map.json"
        malformed_route = b"\xef\xbb\xbf{not-json"
        route_path.write_bytes(malformed_route)
        malformed = activation_receipt._static_identity(package)
        assert malformed is not first
        assert malformed["routeMap"] == {}
        assert malformed["routeMapReady"] is False
        assert malformed["routeMapHash"] == hashlib.sha256(malformed_route).hexdigest()

        # Missing inputs remain uncached so a later package repair is visible.
        capabilities_path = package / "capabilities.json"
        capabilities_path.unlink()
        original_reader = activation_receipt._read_static_json_with_hash
        static_read_count = 0

        def counted_static_reader(path: Path):
            nonlocal static_read_count
            static_read_count += 1
            return original_reader(path)

        activation_receipt._read_static_json_with_hash = counted_static_reader
        try:
            missing = activation_receipt._static_identity(package)
            assert missing["capabilitiesReady"] is False
            assert missing["capabilitiesHash"] == ""
            first_missing_read_count = static_read_count
            activation_receipt._static_identity(package)
            assert static_read_count > first_missing_read_count
        finally:
            activation_receipt._read_static_json_with_hash = original_reader
            activation_receipt._STATIC_IDENTITY_CACHE.clear()
    print("runtime_activation_static_identity_regression: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
