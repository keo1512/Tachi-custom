"""Fail packaging when the native hosts or their verified resources are missing."""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import stat
import zipfile

from configure_ios_tachi_runtime import NATIVE_LIBRARIES, macho
from native_extension_engine.build import sha256, ARRAY_DECODER_RESOURCE, ARRAY_DECODER_BYTES, ARRAY_DECODER_SHA256
from package_jvm_frameworks import alias_path, executable_path, native_records, verify_layout

BOOTSTRAP_JARS = ("resources.jar", "rt.jar", "jsse.jar", "jce.jar", "charsets.jar", "jfr.jar")


def array_decoder(archive: zipfile.ZipFile) -> None:
    try:
        entry = archive.getinfo(ARRAY_DECODER_RESOURCE)
    except KeyError as failure:
        raise ValueError("Dex2jar primitive-array decoder template is missing") from failure
    if entry.file_size != ARRAY_DECODER_BYTES:
        raise ValueError("Dex2jar primitive-array decoder template does not match its pinned upstream bytes")
    payload = archive.read(entry)
    if payload[:4] != b"\xca\xfe\xba\xbe" or int.from_bytes(payload[6:8], "big") != 52 or \
            hashlib.sha256(payload).hexdigest() != ARRAY_DECODER_SHA256:
        raise ValueError("Dex2jar primitive-array decoder template does not match its pinned Java8 upstream bytes")


def inside(path: Path, root: Path) -> None:
    if not path.resolve().is_relative_to(root):
        raise ValueError("Packaged runtime resource escapes the application")


def frameworks_symlinks(root: Path) -> None:
    if not root.is_dir() or root.is_symlink():
        raise ValueError("The application Frameworks directory is missing or redirected")
    for path in root.rglob("*"):
        if not path.is_symlink():
            continue
        if Path(os.readlink(path)).is_absolute():
            raise ValueError("A Frameworks symlink must use a relative target")
        try:
            target = path.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise ValueError("A Frameworks symlink is unresolved") from error
        if not target.is_relative_to(root):
            raise ValueError("A Frameworks symlink escapes the Frameworks directory")


def jar(path: Path, app: Path, required_member: str | None = None) -> None:
    inside(path, app)
    if not path.is_file():
        raise ValueError("A required Java bootstrap resource is missing: " + path.name)
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError("Packaged Java resource failed CRC verification: " + path.name)
        if required_member is not None and required_member not in archive.namelist():
            raise ValueError("The Java bootstrap resource is incomplete: " + path.name)


def bundle(app: Path, name: str) -> Path:
    found = [path for path in app.rglob(name + ".bundle") if path.is_dir()]
    if len(found) != 1:
        raise ValueError(f"Expected exactly one {name} resource bundle")
    result = found[0]
    inside(result, app)
    if result.is_symlink():
        raise ValueError("The runtime resource bundle is redirected")
    return result


def verify(app: Path) -> dict:
    app = app.resolve()
    frameworks_symlinks(app / "Frameworks")
    tachi = bundle(app, "TachiRuntime")
    vbook = bundle(app, "VbookRuntime")
    manifest = tachi / "licenses/upstream-provenance.json"
    inside(manifest, app)
    provenance = json.loads(manifest.read_text())
    if provenance.get("nativeLayoutVersion") != 2:
        raise ValueError("The JVM must be packaged as native framework layout version 2")
    native_layout = verify_layout(app, tachi, provenance)
    inside(tachi / "licenses/SOURCE.txt", app)
    if not (tachi / "licenses/SOURCE.txt").is_file():
        raise ValueError("The packaged runtime is missing corresponding source references")
    engine = tachi / "engine"
    for filename, metadata in (("extension-host.jar", "host"),
                               ("extension-dependencies.jar", "dependencies")):
        path = engine / filename
        inside(path, app)
        if sha256(path) != provenance[metadata]["sha256"]:
            raise ValueError("Packaged Java resource does not match its prepared provenance")
        with zipfile.ZipFile(path) as archive:
            if archive.testzip() is not None:
                raise ValueError("Packaged Java resource failed CRC verification")
            if filename == "extension-host.jar" and \
                    "dev/tachibooks/engine/ExtensionHost.class" not in archive.namelist():
                raise ValueError("The Java host entrypoint is missing")
            if filename == "extension-dependencies.jar":
                array_decoder(archive)
    jre = tachi / "jre"
    for filename in BOOTSTRAP_JARS:
        jar(jre / "lib" / filename, app, "java/lang/Object.class" if filename == "rt.jar" else None)
    for filename in ("cacerts", "java.security", "java.policy"):
        path = jre / "lib/security" / filename
        inside(path, app)
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError("A required Java security resource is missing: " + filename)
    extension_directory = jre / "lib/ext"
    inside(extension_directory, app)
    if not extension_directory.is_dir():
        raise ValueError("The Java extension provider directory is missing")
    for filename in ("sunec.jar", "sunjce_provider.jar"):
        jar(extension_directory / filename, app)
    for path in extension_directory.glob("*.jar"):
        jar(path, app)
    host = vbook / "host.js"
    inside(host, app)
    if not host.is_file() or host.stat().st_size == 0:
        raise ValueError("The vBook script host is missing")
    for name in ("tachi_runtime", "vbook_runtime"):
        library = app / "Frameworks" / (name + ".framework") / name
        inside(library, app)
        macho(library)
    return {
        "tachiHostSha256": provenance["host"]["sha256"],
        "tachiDependenciesSha256": provenance["dependencies"]["sha256"],
        "nativeLibraries": native_layout["frameworks"],
        "nativeLayoutVersion": native_layout["nativeLayoutVersion"],
        "bootstrapJars": len(BOOTSTRAP_JARS),
        "arrayDecoderSha256": ARRAY_DECODER_SHA256,
        "vbookHostSha256": sha256(host),
        "deviceRuntimeVerified": False,
    }


def verify_archive(ipa: Path) -> dict:
    """Check the final ZIP, including aliases that must survive ditto copying.

    Runner.app has already passed verify() before archiving. This second check
    rejects lost/dereferenced aliases or changed native/host bytes in the actual
    artifact without extracting or executing its contents.
    """
    prefix = "Payload/Runner.app/"
    with zipfile.ZipFile(ipa) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if len(names) != len(set(names)):
            raise ValueError("The IPA contains duplicate ZIP entries")
        by_name = {entry.filename: entry for entry in entries}
        for name in names:
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name:
                raise ValueError("The IPA contains an unsafe ZIP path")
        if prefix + "Info.plist" not in by_name or archive.testzip() is not None:
            raise ValueError("The IPA is incomplete or failed ZIP CRC verification")
        manifests = [name for name in names if name.startswith(prefix) and
                     name.endswith("/TachiRuntime.bundle/licenses/upstream-provenance.json")]
        if len(manifests) != 1:
            raise ValueError("Expected exactly one TachiRuntime provenance in the IPA")
        manifest = manifests[0]
        if by_name[manifest].file_size > 1024 * 1024:
            raise ValueError("The IPA runtime provenance exceeds its size limit")
        provenance = json.loads(archive.read(manifest))
        if provenance.get("nativeLayoutVersion") != 2:
            raise ValueError("The IPA JVM framework layout version is missing")
        records = native_records(provenance)
        resource = manifest.removesuffix("licenses/upstream-provenance.json")

        def check_file(name: str, expected_hash: str) -> None:
            entry = by_name.get(name)
            if entry is None or entry.is_dir() or stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError("The IPA runtime executable/resource is missing or redirected")
            digest = hashlib.sha256()
            with archive.open(entry) as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            if digest.hexdigest() != expected_hash:
                raise ValueError("The IPA runtime bytes do not match prepared provenance")

        for relative, record in records.items():
            binary = executable_path(relative)
            alias = alias_path(relative)
            if record.get("framework") != binary or record.get("alias") != alias or \
                    not record.get("installNamesPatched"):
                raise ValueError("The IPA JVM framework provenance is inconsistent")
            check_file(prefix + binary, record.get("sha256"))
            entry = by_name.get(prefix + alias)
            if entry is None or entry.create_system != 3 or not stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError("The IPA lost a required JVM library symlink alias")
            expected_target = binary.removeprefix("Frameworks/").encode("utf-8")
            if entry.file_size != len(expected_target) or archive.read(entry) != expected_target:
                raise ValueError("The IPA JVM library alias has an unexpected target")
            if resource + "jre/" + relative in by_name:
                raise ValueError("Standalone JVM native code remains in the IPA resource bundle")
        for filename, key in (("extension-host.jar", "host"),
                              ("extension-dependencies.jar", "dependencies")):
            check_file(resource + "engine/" + filename, provenance[key]["sha256"])
            if filename == "extension-dependencies.jar":
                with zipfile.ZipFile(io.BytesIO(archive.read(resource + "engine/" + filename))) as dependencies:
                    array_decoder(dependencies)
    return {"nativeAliases": len(records), "nativeLayoutVersion": 2,
            "arrayDecoderSha256": ARRAY_DECODER_SHA256,
            "zipIntegrityVerified": True, "deviceRuntimeVerified": False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.app.resolve()), indent=2))


if __name__ == "__main__":
    main()
