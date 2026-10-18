"""Prepare pinned Zero/JNI resources without running downloaded iOS binaries.

macOS rewrites only bundled Mach-O install names and removes obsolete rpaths;
the app still needs normal code signing. Windows prepares/audits the same source
but cannot confirm dyld startup or the iPhone extension runtime.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import uuid

from native_extension_engine.build import (
    DEPENDENCY_BYTES, DEPENDENCY_SHA256, DEPENDENCY_URL,
    LEGACY_DEPENDENCY_BYTES, LEGACY_DEPENDENCY_SHA256, LEGACY_DEPENDENCY_URL,
    build_dependencies, build_api, merge_api, merge_portable_zstd, build_host, sha256,
)

ROOT = Path(__file__).resolve().parents[1]
SPEC = json.loads((ROOT / "tools/native_extension_engine/upstream.json").read_text())
NATIVE_LIBRARIES = {
    "lib/server/libjvm.dylib", "lib/server/libffi.8.dylib",
    "lib/libjava.dylib", "lib/libverify.dylib", "lib/libzip.dylib",
    "lib/libnet.dylib", "lib/libnio.dylib", "lib/libsunec.dylib",
    "lib/libmanagement.dylib",
}


def fetch(url: str, destination: Path, digest: str, size: int | None = None) -> Path:
    if destination.exists():
        if sha256(destination) != digest or size is not None and destination.stat().st_size != size:
            raise ValueError("Cached upstream file checksum mismatch: " + destination.name)
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".pending")
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "TachiBooks-runtime-builder"})
        with urllib.request.urlopen(request, timeout=90) as response, temporary.open("wb") as output:
            total = 0
            while block := response.read(1024 * 1024):
                total += len(block)
                if total > (size if size is not None else 4 * 1024 * 1024):
                    raise ValueError("Upstream file exceeds expected size")
                output.write(block)
            output.flush()
            os.fsync(output.fileno())
        if size is not None and total != size or sha256(temporary) != digest:
            raise ValueError("Downloaded upstream file checksum mismatch")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def local_or_fetch(local: str | None, cache: Path, asset: dict) -> Path:
    path = Path(local).resolve() if local else fetch(asset["url"], cache, asset["sha256"], asset["bytes"])
    if path.stat().st_size != asset["bytes"] or sha256(path) != asset["sha256"]:
        raise ValueError("Supplied upstream archive checksum mismatch")
    return path


def extract_jre(archive: Path, destination: Path) -> None:
    seen: set[str] = set()
    total = 0
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or "\\" in member.name:
                raise ValueError("Unsafe JRE archive path")
            if member.name in seen:
                raise ValueError("Duplicate JRE archive member")
            seen.add(member.name)
            if member.isdir():
                continue
            if not member.isfile():
                raise ValueError("JRE archive contains a link or unsupported entry")
            if not path.parts or path.parts[0] != "java-8-openjdk":
                raise ValueError("Unexpected JRE root")
            relative = PurePosixPath(*path.parts[1:])
            if relative.parts[0] == "bin" or relative.suffix == ".dylib" and relative.as_posix() not in NATIVE_LIBRARIES:
                continue
            if member.size < 0 or member.size > 64 * 1024 * 1024:
                raise ValueError("Invalid JRE member size")
            total += member.size
            if total > 128 * 1024 * 1024:
                raise ValueError("JRE size limit exceeded")
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            data = source.extractfile(member).read()
            if len(data) != member.size:
                raise ValueError("Truncated JRE member")
            target.write_bytes(data)
    if not (destination / "lib/rt.jar").is_file():
        raise ValueError("JRE bootstrap classes are missing")
    for name in NATIVE_LIBRARIES:
        if not (destination / name).is_file():
            raise ValueError("JRE native dependency is missing: " + name)


def macho(path: Path) -> dict:
    data = path.read_bytes()
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe" or struct.unpack_from("<I", data, 4)[0] != 0x100000C:
        raise ValueError("Native runtime is not an arm64 Mach-O")
    commands, length = struct.unpack_from("<II", data, 16)
    if 32 + length > len(data):
        raise ValueError("Truncated Mach-O load commands")
    offset = 32
    result = {"dependencies": [], "rpaths": [], "id": None, "iosDevice": False}
    for _ in range(commands):
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > 32 + length:
            raise ValueError("Invalid Mach-O load command")
        if command == 0x32:
            result["iosDevice"] = struct.unpack_from("<I", data, offset + 8)[0] == 2
        elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS, used by bundled libffi.
            result["iosDevice"] = True
        if command in (0xC, 0xD, 0x80000018, 0x8000001F, 0x8000001C):
            start = struct.unpack_from("<I", data, offset + 8)[0]
            if start < 12 or start >= size:
                raise ValueError("Invalid Mach-O string offset")
            value = data[offset + start:offset + size].split(b"\0", 1)[0].decode("utf-8")
            if command == 0xD:
                result["id"] = value
            elif command == 0x8000001C:
                result["rpaths"].append(value)
            else:
                result["dependencies"].append(value)
        offset += size
    if not result["iosDevice"]:
        raise ValueError("Runtime Mach-O targets a simulator or another platform")
    return result


def configure_loaders(jre: Path) -> list[dict]:
    libraries = {path.name: path for path in jre.rglob("*.dylib")}
    audit = []
    for path in sorted(libraries.values()):
        info = macho(path)
        replacements = []
        for dependency in info["dependencies"]:
            if dependency.startswith("@rpath/"):
                name = PurePosixPath(dependency).name
                if name not in libraries:
                    raise ValueError("Unresolved native runtime dependency: " + name)
                relative = os.path.relpath(libraries[name], path.parent).replace(os.sep, "/")
                replacements.append((dependency, "@loader_path/" + relative))
            elif not dependency.startswith(("/usr/lib/", "/System/Library/Frameworks/")):
                raise ValueError("Unexpected external native dependency")
        if sys.platform == "darwin":
            command = ["xcrun", "install_name_tool", "-id", "@rpath/" + path.name]
            for old, new in replacements:
                command += ["-change", old, new]
            for rpath in info["rpaths"]:
                if rpath.startswith("/usr/lib/jvm/") or ".dylib.framework" in rpath:
                    command += ["-delete_rpath", rpath]
            subprocess.run(command + [str(path)], check=True)
            info = macho(path)
            if any(value.startswith("@rpath/") for value in info["dependencies"]):
                raise ValueError("Native dependency rewrite did not complete")
        info.update({"file": path.relative_to(jre).as_posix(), "sha256": sha256(path),
                     "installNamesPatched": sys.platform == "darwin"})
        audit.append(info)
    return audit


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zero-archive")
    parser.add_argument("--dependency-archive")
    parser.add_argument("--legacy-dependency-archive")
    parser.add_argument("--javac")
    parser.add_argument("--java")
    args = parser.parse_args()
    cache = ROOT / ".dart_tool/tachi-runtime-cache"
    cache.mkdir(parents=True, exist_ok=True)
    zero = local_or_fetch(args.zero_archive, cache / "ios-zero.tar.xz", SPEC["zero"])
    dependencies = local_or_fetch(args.dependency_archive, cache / "dependencies.jar", {
        "url": DEPENDENCY_URL, "sha256": DEPENDENCY_SHA256, "bytes": DEPENDENCY_BYTES})
    legacy = local_or_fetch(args.legacy_dependency_archive, cache / "android-compatibility.jar", {
        "url": LEGACY_DEPENDENCY_URL, "sha256": LEGACY_DEPENDENCY_SHA256, "bytes": LEGACY_DEPENDENCY_BYTES})
    decoder = local_or_fetch(None, cache / "aircompressor-0.27.jar", SPEC["portableZstd"])
    crypto = local_or_fetch(None, cache / "bcprov-jdk15to18-1.86.jar", SPEC["cryptoProvider"])
    decoder_notice = fetch(SPEC["portableZstd"]["licenseUrl"], cache / "aircompressor-LICENSE.txt", SPEC["portableZstd"]["licenseSha256"])
    with tempfile.TemporaryDirectory(prefix="prepare-", dir=cache) as temporary:
        staging = Path(temporary) / "Runtime"
        staging.mkdir()
        extract_jre(zero, staging / "jre")
        dependency_jar = staging / "engine/extension-dependencies.jar"
        dependency_info = build_dependencies(dependencies, dependency_jar, legacy)
        # A JCE provider must retain the upstream JAR signature. Do not merge
        # or rewrite its bytes into the ordinary dependency JAR.
        shutil.copyfile(crypto, staging / "engine/bcprov.jar")
        compiler = args.javac or shutil.which("javac")
        java = args.java or str(Path(compiler).with_name("java.exe" if os.name == "nt" else "java")) if compiler else args.java or shutil.which("java")
        if not java:
            raise ValueError("A JDK runtime is required to compile the official Kotlin source API")
        api_jar, api_info = build_api(dependency_jar, cache / "source-api-build", java)
        merge_api(dependency_jar, api_jar)
        dependency_info["portableZstd"] = merge_portable_zstd(dependency_jar, decoder, decoder_notice)
        dependency_info["libraryOnlySha256"] = dependency_info["sha256"]
        dependency_info["sha256"] = sha256(dependency_jar)
        dependency_info["sourceApi"] = api_info
        host_info = build_host(staging / "engine/extension-dependencies.jar", staging / "engine/extension-host.jar", Path(temporary), args.javac)
        commit = SPEC["zero"]["sourceCommit"]
        base = "https://raw.githubusercontent.com/PojavLauncherTeam/openjdk-multiarch-jdk8u/" + commit + "/"
        for item in SPEC["files"]:
            source = fetch(base + item["sourcePath"], cache / "source-files" / item["name"], item["sha256"])
            destination = staging / item["name"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
        provenance = {"zero": SPEC["zero"], "dependencies": dependency_info, "host": host_info,
                      "cryptoProvider": SPEC["cryptoProvider"],
                      "nativeLibraries": configure_loaders(staging / "jre"), "deviceRuntimeVerified": False,
                      "limitations": ["Pinned prebuilt Zero runtime has an internal 2022 runtime version; its maintenance and source correspondence require verification",
                                      "On-device API 1.6 extension compatibility is not verified",
                                      "Android-only browser/graphics APIs require native host adapters",
                                      "Compilation and package inspection do not prove iOS JVM startup"]}
        (staging / "licenses/upstream-provenance.json").write_text(json.dumps(provenance, indent=2), encoding="utf-8")
        (staging / "licenses/SOURCE.txt").write_text(
            "OpenJDK GPL-2.0 with its stated Classpath/assembly exceptions; retain the included notices.\n"
            "Corresponding OpenJDK source: " + SPEC["zero"]["sourceArchive"] + "\n"
            "Runtime build scripts: https://github.com/PojavLauncherTeam/android-openjdk-build-multiarch/tree/jre8-99f3f8b\n"
            "Java library/source API: https://github.com/Suwayomi/Suwayomi-Server/tree/v2.4.2366\n"
            "Android compatibility source: https://github.com/Suwayomi/Suwayomi-Server/tree/v0.7.0\n"
            "Reviewed Android hierarchy and Java8 Preference port: https://github.com/Suwayomi/Suwayomi-Server/tree/40bc5da57820324ed0ae724cbbc020cc4673b594/AndroidCompat\n"
            "Those MPL source files and provenance are included in extension-host.jar.\n"
            "Dependency original license/notices remain inside extension-dependencies.jar.\n"
            "Bouncy Castle signed provider: " + SPEC["cryptoProvider"]["source"] + "; license/notices remain inside engine/bcprov.jar.\n"
            "The native changes replace bundled dylib install names/rpaths only, via this configure script.\n"
            "Provide corresponding source/notices with any distributed runtime; source references are not an audit of all redistribution obligations.\n",
            encoding="utf-8")
        target = ROOT / "packages/tachi_runtime/ios/Runtime"
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            target.rename(cache / ("previous-Runtime-" + uuid.uuid4().hex))
        staging.rename(target)
        print(json.dumps({"runtime": str(target), "hostSha256": host_info["sha256"],
                          "dependenciesSha256": dependency_info["sha256"], "nativeLibraries": len(provenance["nativeLibraries"]),
                          "installNamesPatched": sys.platform == "darwin", "deviceRuntimeVerified": False}))


if __name__ == "__main__":
    main()
