"""Run fast checks before native builds; reuse them only for identical inputs."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from run_build_phase import run_phase


ROOT = Path(__file__).resolve().parents[1]
FLUTTER_VERSION = "3.47.4"
FLUTTER_REVISION = "9584c6713b324636289d067944a46fd6b49df14b"
INPUT_ROOTS = {"lib", "test", "ios", "packages", "tools", "assets", ".github"}
INPUT_FILES = {"pubspec.yaml", "pubspec.lock", "analysis_options.yaml", "codemagic.yaml"}
CHECKS = ("locked-pub-get", "flutter-analyze", "flutter-tests", "build-helper-tests", "swift-source-checks")


def source_digest(root: Path) -> str:
    names = set(subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root, timeout=30).decode("utf-8").split("\0"))
    tracked = set(subprocess.check_output(
        ["git", "ls-files", "--cached", "-z"], cwd=root, timeout=30).decode("utf-8").split("\0"))
    # CocoaPods creates a lock on first resolution. Once committed, it becomes
    # a checked input; a generated untracked lock is retained as CI evidence.
    if "ios/Podfile.lock" not in tracked:
        names.discard("ios/Podfile.lock")
    # This ignored input is deliberately configured before the checks. Never
    # publish its contents; a hash only binds the receipt to the same config.
    firebase = "ios/Runner/GoogleService-Info.plist"
    if (root / firebase).is_file():
        names.add(firebase)
    digest = hashlib.sha256()
    for name in sorted(names - {""}):
        if name.split("/")[0] not in INPUT_ROOTS and name not in INPUT_FILES:
            continue
        path = root / name
        # git can list tracked files deleted from the working tree. Their
        # absence also contributes, so deleting one invalidates an old receipt.
        value = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "missing"
        digest.update(name.encode("utf-8") + b"\0" + value.encode("ascii") + b"\n")
    return digest.hexdigest()


def verify_receipt(root: Path, path: Path) -> dict:
    receipt = json.loads(path.read_text(encoding="utf-8"))
    if (receipt.get("schema") != 1 or receipt.get("sourceSha256") != source_digest(root)
            or receipt.get("flutterVersion") != FLUTTER_VERSION
            or receipt.get("flutterRevision") != FLUTTER_REVISION
            or receipt.get("checks") != list(CHECKS)):
        raise ValueError("Preflight receipt is incomplete or source/config changed; rerun preflight")
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, default=ROOT / "artifacts/ios-preflight.json")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.verify:
        verify_receipt(ROOT, args.receipt)
        print("Preflight source/config fingerprint matches; analyzed tests are reused.")
        return 0
    if sys.platform != "darwin":
        parser.error("iOS preflight requires macOS/Xcode; host fixture tests are separate")
    # A failed retry must never leave a prior successful receipt usable.
    args.receipt.unlink(missing_ok=True)
    before = source_digest(ROOT)
    version = json.loads(subprocess.check_output(
        ["flutter", "--version", "--machine"], cwd=ROOT, text=True, timeout=60))
    if (version.get("frameworkVersion") != FLUTTER_VERSION
            or version.get("frameworkRevision") != FLUTTER_REVISION):
        parser.error("Use the pinned official Flutter 3.47.4 revision")
    phases = [
        (CHECKS[0], ["flutter", "pub", "get", "--enforce-lockfile"], 240),
        (CHECKS[1], ["flutter", "analyze", "--no-pub"], 240),
        (CHECKS[2], ["flutter", "test", "--no-pub"], 600),
        (CHECKS[3], [sys.executable, "-B", "-m", "unittest",
                    "test_run_build_phase", "test_ios_build_preflight",
                    "test_ios_build_pipeline", "test_package_jvm_frameworks",
                    "test_check_native_runtime_bundle", "test_configure_firebase_ios"], 120),
        (CHECKS[4], [sys.executable, "tools/check_ios_native_sources.py", "--swift-only"], 600),
    ]
    for name, command, limit in phases:
        # unittest imports the build helpers from tools, while Flutter and the
        # native checker run at the application root.
        working = ROOT / "tools" if name == CHECKS[3] else ROOT
        previous = Path.cwd()
        try:
            os.chdir(working)
            result = run_phase(name, command, ROOT / f"artifacts/{name}.log", timeout=limit,
                               status=ROOT / f"artifacts/{name}.status.json")
        finally:
            os.chdir(previous)
        if result:
            return result
    if source_digest(ROOT) != before:
        raise ValueError("Build inputs changed during preflight; checks must be rerun")
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps({
        "schema": 1, "sourceSha256": before, "checks": list(CHECKS),
        "flutterVersion": FLUTTER_VERSION, "flutterRevision": FLUTTER_REVISION,
        "nativeRuntimeVerified": False,
    }, indent=2) + "\n", encoding="utf-8")
    print("Preflight passed. Native Pods compilation and device acceptance remain separate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
