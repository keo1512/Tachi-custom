"""Package the verified JVM libraries as normally signable iOS frameworks.

Java bootstrap data stays in TachiRuntime.bundle. Relative aliases in the
top-level Frameworks directory preserve the JVM's libjava/libzip lookup names;
the executable code lives only in flat framework bundles. This does not sign
code or prove JVM startup on an iPhone.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile

from configure_ios_tachi_runtime import NATIVE_LIBRARIES, macho
from native_extension_engine.build import sha256

FRAMEWORK_NAMES = {
    "lib/server/libjvm.dylib": "TachiJVM",
    "lib/server/libffi.8.dylib": "TachiFFI",
    "lib/libjava.dylib": "TachiJava",
    "lib/libverify.dylib": "TachiVerify",
    "lib/libzip.dylib": "TachiZip",
    "lib/libnet.dylib": "TachiNet",
    "lib/libnio.dylib": "TachiNio",
    "lib/libsunec.dylib": "TachiSunec",
    "lib/libmanagement.dylib": "TachiManagement",
}


def runtime_bundle(app: Path) -> Path:
    found = [path for path in app.rglob("TachiRuntime.bundle") if path.is_dir()]
    if len(found) != 1:
        raise ValueError("Expected exactly one TachiRuntime resource bundle")
    bundle = found[0]
    if bundle.is_symlink() or not bundle.resolve().is_relative_to(app):
        raise ValueError("Runtime bundle must stay inside the application")
    return bundle


def executable_path(relative: str) -> str:
    name = FRAMEWORK_NAMES[relative]
    return f"Frameworks/{name}.framework/{name}"


def alias_path(relative: str) -> str:
    return "Frameworks/" + Path(relative).name


def native_records(provenance: dict) -> dict[str, dict]:
    records = provenance.get("nativeLibraries")
    if not isinstance(records, list) or len(records) != len(FRAMEWORK_NAMES):
        raise ValueError("The verified native library list is incomplete")
    result = {}
    for record in records:
        if not isinstance(record, dict) or record.get("file") not in FRAMEWORK_NAMES:
            raise ValueError("Unexpected native library record")
        if record["file"] in result:
            raise ValueError("Duplicate native library record")
        result[record["file"]] = record
    if set(result) != NATIVE_LIBRARIES:
        raise ValueError("The verified native library list does not match the JVM")
    return result


def inside(path: Path, root: Path) -> None:
    if not path.resolve().is_relative_to(root):
        raise ValueError("Native runtime path escapes the application")


def framework_macho(path: Path) -> dict:
    info = macho(path)
    # Framework executables are dynamic libraries, not arbitrary executable
    # Mach-O files that happen to target the iOS device architecture.
    with path.open("rb") as stream:
        header = stream.read(16)
    if struct.unpack_from("<I", header, 12)[0] != 6:  # MH_DYLIB
        raise ValueError("JVM framework executable must be a dynamic library")
    return info


def verify_layout(app: Path, bundle: Path, provenance: dict) -> dict:
    if provenance.get("nativeLayoutVersion") != 2:
        raise ValueError("JVM framework layout version is missing")
    records = native_records(provenance)
    if (app / "Frameworks").is_symlink():
        raise ValueError("Application Frameworks directory must not be a symlink")
    binaries = {relative: app / executable_path(relative) for relative in records}
    for relative, record in records.items():
        binary = binaries[relative]
        alias = app / alias_path(relative)
        name = FRAMEWORK_NAMES[relative]
        expected_target = f"{name}.framework/{name}"
        if record.get("framework") != executable_path(relative) or record.get("alias") != alias_path(relative):
            raise ValueError("JVM framework provenance path is inconsistent")
        if not binary.is_file() or binary.is_symlink() or binary.parent.is_symlink():
            raise ValueError("JVM framework executable is missing or redirected")
        inside(binary, app)
        if not alias.is_symlink() or os.readlink(alias) != expected_target:
            raise ValueError("JVM library alias is missing or not relative to its framework")
        inside(alias, app)
        if alias.resolve() != binary.resolve():
            raise ValueError("JVM library alias targets a different executable")
        if not record.get("installNamesPatched") or sha256(binary) != record.get("sha256"):
            raise ValueError("JVM framework executable does not match its provenance")
        with (binary.parent / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if info.get("CFBundleExecutable") != name or info.get("CFBundlePackageType") != "FMWK":
            raise ValueError("JVM framework bundle metadata is inconsistent")
        native = framework_macho(binary)
        if native["id"] != f"@rpath/{name}.framework/{name}":
            raise ValueError("JVM framework install name is inconsistent")
        for dependency in native["dependencies"]:
            if dependency.startswith("@loader_path/"):
                target = binary.parent / dependency.removeprefix("@loader_path/")
                inside(target, app)
                if target.resolve() not in {path.resolve() for path in binaries.values()}:
                    raise ValueError("JVM framework dependency is not a packaged executable")
            elif not dependency.startswith(("/usr/lib/", "/System/Library/Frameworks/")):
                raise ValueError("JVM framework dependency is external or unresolved")
        if (bundle / "jre" / relative).exists():
            raise ValueError("Standalone JVM native code remains in the resource bundle")
    return {"nativeLayoutVersion": 2, "frameworks": len(records), "deviceRuntimeVerified": False}


def package(app: Path) -> dict:
    if sys.platform != "darwin":
        raise ValueError("JVM framework packaging requires macOS install_name_tool")
    app = app.resolve()
    if not app.is_dir():
        raise ValueError("The built application does not exist")
    bundle = runtime_bundle(app)
    manifest = bundle / "licenses/upstream-provenance.json"
    inside(manifest, app)
    original_manifest = manifest.read_bytes()
    provenance = json.loads(original_manifest)
    if provenance.get("nativeLayoutVersion") == 2:
        return verify_layout(app, bundle, provenance)
    if provenance.get("nativeLayoutVersion") not in (None, 1):
        raise ValueError("Unsupported JVM native resource layout")
    records = native_records(provenance)
    jre = bundle / "jre"
    framework_root = app / "Frameworks"
    inside(framework_root, app)
    if framework_root.is_symlink():
        raise ValueError("Application Frameworks directory must not be a symlink")
    sources = {relative: jre / relative for relative in records}
    by_source = {}
    source_infos = {}
    for relative, source in sources.items():
        inside(source, app)
        if not source.is_file() or source.is_symlink():
            raise ValueError("Verified JVM native library is missing or redirected")
        if not records[relative].get("installNamesPatched") or sha256(source) != records[relative].get("sha256"):
            raise ValueError("JVM native source does not match its prepared provenance")
        source_infos[relative] = framework_macho(source)
        by_source[source.resolve()] = relative
        target = app / executable_path(relative)
        alias = app / alias_path(relative)
        if target.parent.exists() or alias.exists() or alias.is_symlink():
            raise ValueError("JVM framework destination already exists")
    framework_root.mkdir(exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".jvm-packaging-", dir=framework_root))
    committed = []
    deleted_sources = []
    manifest_changed = False
    try:
        updated = json.loads(original_manifest)
        updated["nativeLayoutVersion"] = 2
        updated_records = native_records(updated)
        for relative, source in sources.items():
            name = FRAMEWORK_NAMES[relative]
            directory = stage / f"{name}.framework"
            directory.mkdir()
            binary = directory / name
            shutil.copyfile(source, binary)
            binary.chmod(0o755)
            backup = stage / "original" / relative
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, backup)
            info = source_infos[relative]
            command = ["xcrun", "install_name_tool", "-id", f"@rpath/{name}.framework/{name}"]
            for dependency in info["dependencies"]:
                if dependency.startswith("@loader_path/"):
                    old_target = source.parent / dependency.removeprefix("@loader_path/")
                    target_relative = by_source.get(old_target.resolve())
                    if target_relative is None:
                        raise ValueError("JVM native dependency is not a verified packaged library")
                    target_name = FRAMEWORK_NAMES[target_relative]
                    command += ["-change", dependency, f"@loader_path/../{target_name}.framework/{target_name}"]
                elif not dependency.startswith(("/usr/lib/", "/System/Library/Frameworks/")):
                    raise ValueError("JVM native dependency has not been prepared for the application")
            for rpath in info["rpaths"]:
                if rpath.startswith("/usr/lib/jvm/") or ".dylib.framework" in rpath:
                    command += ["-delete_rpath", rpath]
            subprocess.run(command + [str(binary)], check=True)
            with (directory / "Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleExecutable": name, "CFBundleIdentifier": "dev.tachibooks.runtime." + name.lower(),
                              "CFBundleName": name, "CFBundlePackageType": "FMWK", "CFBundleShortVersionString": "1.0",
                              "CFBundleVersion": "1", "CFBundleSupportedPlatforms": ["iPhoneOS"],
                              "MinimumOSVersion": "15.0"}, stream)
            rewritten = framework_macho(binary)
            record = updated_records[relative]
            record.update(rewritten)
            record.update({"framework": executable_path(relative), "alias": alias_path(relative),
                           "originalSha256": records[relative]["sha256"], "sha256": sha256(binary),
                           "installNamesPatched": True})
        # All tools/validation run on copies. No verified source is removed
        # until all nine frameworks and their lookup aliases are ready.
        for relative in records:
            name = FRAMEWORK_NAMES[relative]
            destination = framework_root / f"{name}.framework"
            (stage / destination.name).rename(destination)
            committed.append(destination)
            alias = app / alias_path(relative)
            alias.symlink_to(f"{name}.framework/{name}")
            committed.append(alias)
        pending = stage / "upstream-provenance.json"
        pending.write_text(json.dumps(updated, indent=2) + "\n", encoding="utf-8")
        pending.replace(manifest)
        manifest_changed = True
        for relative, source in sources.items():
            source.unlink()
            deleted_sources.append(relative)
        return verify_layout(app, bundle, updated)
    except BaseException:
        for relative in deleted_sources:
            shutil.copyfile(stage / "original" / relative, sources[relative])
        if manifest_changed:
            pending = stage / "restore-provenance.json"
            pending.write_bytes(original_manifest)
            pending.replace(manifest)
        for path in reversed(committed):
            inside(path, app)
            if path.is_symlink():
                path.unlink()
            elif path.is_dir():
                shutil.rmtree(path)
        raise
    finally:
        # Restrict recursive cleanup to this generated directory inside the
        # already validated application's Frameworks directory.
        inside(stage, framework_root)
        if stage.name.startswith(".jvm-packaging-") and stage.parent == framework_root:
            shutil.rmtree(stage)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    print(json.dumps(package(args.app), indent=2))


if __name__ == "__main__":
    main()
