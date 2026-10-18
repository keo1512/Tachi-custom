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
QUICK_CHECKS = ("locked-pub-get", "build-helper-tests", "swift-source-checks")
CHECKS = QUICK_CHECKS + ("flutter-analyze", "flutter-tests")


def source_digest(root: Path) -> str:
    names = set(subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root, timeout=30).decode("utf-8").split("\0"))
    # Dependency integration is complete before the reusable receipt is made.
    # Bind even an untracked/ignored first Pod resolution, plus private config,
    # without publishing either file's contents.
    for name in ("ios/Podfile.lock", "ios/Runner/GoogleService-Info.plist"):
        if (root / name).is_file():
            names.add(name)
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
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--verify", action="store_true")
    mode.add_argument("--quick", action="store_true",
                      help="Check build helpers and Swift before dependency setup; never issue a reusable receipt")
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
        ("locked-pub-get", ["flutter", "pub", "get", "--enforce-lockfile"], 240),
        ("build-helper-tests", [sys.executable, "-B", "-m", "unittest",
                    "test_run_build_phase", "test_ios_build_preflight",
                    "test_ios_build_pipeline", "test_package_jvm_frameworks",
                    "test_check_native_runtime_bundle", "test_configure_firebase_ios"], 120),
        ("swift-source-checks", [sys.executable, "tools/check_ios_native_sources.py", "--swift-only"], 600),
    ]
    if not args.quick:
        phases += [
            ("flutter-analyze", ["flutter", "analyze", "--no-pub"], 240),
            ("flutter-tests", ["flutter", "test", "--no-pub"], 600),
        ]
    for name, command, limit in phases:
        # unittest imports the build helpers from tools, while Flutter and the
        # native checker run at the application root.
        working = ROOT / "tools" if name == "build-helper-tests" else ROOT
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
    if args.quick:
        print("Quick checks passed; no reusable receipt issued. Prepare Pods, then run full preflight.")
        return 0
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
