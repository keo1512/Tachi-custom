"""Check owned iOS sources against real Xcode/Flutter headers before Pods build.

Runner Swift is type checked for device and simulator. Plugin/test Swift is
parsed only: its external Pods are resolved by the subsequent XCTest build.
The Objective-C/JNI check needs the verified runtime headers prepared first.
These compile checks do not execute native application code.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import subprocess
import sys

from run_build_phase import run_phase


ROOT = Path(__file__).resolve().parents[1]


def flutter_framework(flutter_root: Path, simulator: bool) -> Path:
    variant = "ios-arm64_x86_64-simulator" if simulator else "ios-arm64"
    for mode in ("ios", "ios-release"):
        framework = (flutter_root / "bin/cache/artifacts/engine" / mode /
                     "Flutter.xcframework" / variant / "Flutter.framework")
        if (framework / "Headers/Flutter.h").is_file():
            return framework
    raise ValueError(f"Missing real Flutter framework for {variant}; run flutter precache --ios")


def commands(root: Path, flutter_root: Path, sdk_paths: dict[str, Path], *,
             swift: bool, objc: bool) -> list[tuple[str, list[str]]]:
    checks = []
    runner = sorted((root / "ios/Runner").glob("*.swift"))
    header = root / "ios/Runner/Runner-Bridging-Header.h"
    if swift:
        if not runner or not (header.parent / "GeneratedPluginRegistrant.h").is_file():
            raise ValueError("Missing Runner Swift or generated plugin header; run flutter pub get first")
        others = sorted((root / "ios/RunnerTests").glob("*.swift"))
        others += sorted((root / "packages/vbook_runtime/ios/Classes").glob("*.swift"))
        checks.append(("swift-test-plugin-parse", [
            "xcrun", "swiftc", "-frontend", "-parse", *map(str, others),
        ]))
    include = root / "packages/tachi_runtime/ios/Runtime/include"
    if objc and not all((include / item).is_file() for item in ("jni.h", "darwin/jni_md.h")):
        raise ValueError("Verified JNI headers are missing; prepare the extension engine first")
    for sdk, sdk_path in sdk_paths.items():
        simulator = sdk == "iphonesimulator"
        target = "arm64-apple-ios15.0" + ("-simulator" if simulator else "")
        framework = flutter_framework(flutter_root, simulator)
        cache = root / "artifacts/native-source-module-cache" / sdk
        cache.mkdir(parents=True, exist_ok=True)
        if swift:
            checks.append((f"swift-runner-{sdk}", [
                "xcrun", "swiftc", "-typecheck", "-parse-as-library",
                "-swift-version", "5", "-module-name", "Runner",
                "-target", target, "-sdk", str(sdk_path),
                "-F", str(framework.parent), "-module-cache-path", str(cache),
                "-import-objc-header", str(header),
                *(["-D", "DEBUG"] if simulator else []), *map(str, runner),
            ]))
        if objc:
            sources = sorted((root / "packages/tachi_runtime/ios/Classes").glob("*.m"))
            if not sources:
                raise ValueError("No native extension Objective-C sources found")
            checks.append((f"objc-runtime-{sdk}", [
                "xcrun", "clang", "-fsyntax-only", "-fobjc-arc", "-fblocks", "-fmodules",
                "-target", target, "-isysroot", str(sdk_path),
                "-F", str(framework.parent), f"-fmodules-cache-path={cache}",
                "-I", str(include), "-I", str(include / "darwin"), *map(str, sources),
            ]))
    return checks


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--swift-only", action="store_true")
    group.add_argument("--objc-only", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Native source compilation requires macOS/Xcode; no native check was run")
    flutter = shutil.which("flutter")
    if not flutter:
        parser.error("Flutter must be installed and precached first")
    sdk_paths = {}
    for sdk in ("iphoneos", "iphonesimulator"):
        version = subprocess.check_output(
            ["xcrun", "--sdk", sdk, "--show-sdk-version"], text=True, timeout=30).strip()
        if version.split(".")[0] != "27":
            parser.error(f"Expected iOS 27 SDK, found {sdk} {version}")
        sdk_paths[sdk] = Path(subprocess.check_output(
            ["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True, timeout=30).strip())
    for name, command in commands(ROOT, Path(flutter).resolve().parent.parent, sdk_paths,
                                  swift=not args.objc_only, objc=not args.swift_only):
        code = run_phase(name, command, ROOT / f"artifacts/{name}.log", timeout=180,
                         status=ROOT / f"artifacts/{name}.status.json")
        if code:
            return code
    return 0


if __name__ == "__main__":
    sys.exit(main())
