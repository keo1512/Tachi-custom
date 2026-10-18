"""Copy a compiled Tachimanga IPA and rename editable native branding.

Uses Python's standard library. Does not compile, patch Mach-O, or sign code.
Existing output paths are never overwritten.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import stat
import zipfile


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def plist_bytes(value: dict, original: bytes) -> bytes:
    fmt = plistlib.FMT_BINARY if original.startswith(b"bplist00") else plistlib.FMT_XML
    return plistlib.dumps(value, fmt=fmt, sort_keys=False)


def rename_resource(relative: str, data: bytes) -> bytes:
    if relative == "Info.plist":
        info = plistlib.loads(data)
        info["CFBundleDisplayName"] = "TachiBooks"
        info["CFBundleName"] = "TachiBooks"
        for key in (
            "NSFaceIDUsageDescription",
            "NSLocalNetworkUsageDescription",
            "NSPhotoLibraryUsageDescription",
        ):
            if key in info:
                info[key] = info[key].replace("Tachimanga", "TachiBooks")
        for item in info.get("CFBundleDocumentTypes", []):
            if "CFBundleTypeName" in item:
                item["CFBundleTypeName"] = item["CFBundleTypeName"].replace(
                    "Tachimanga", "TachiBooks"
                )
        for key in ("UTExportedTypeDeclarations", "UTImportedTypeDeclarations"):
            for item in info.get(key, []):
                if "UTTypeDescription" in item:
                    item["UTTypeDescription"] = item["UTTypeDescription"].replace(
                        "Tachimanga", "TachiBooks"
                    )
        return plist_bytes(info, data)

    parts = PurePosixPath(relative).parts
    if len(parts) == 2 and parts[0].endswith(".lproj") and parts[1] in (
        "InfoPlist.strings", "Localizable.strings"
    ):
        strings = plistlib.loads(data)
        # Keep lookup keys, URLs and technical identifiers exactly as supplied.
        for key, value in strings.items():
            if isinstance(value, str) and "://" not in value:
                strings[key] = value.replace("Tachimanga", "TachiBooks")
        if parts[1] == "InfoPlist.strings":
            strings["CFBundleDisplayName"] = "TachiBooks"
            strings["CFBundleName"] = "TachiBooks"
        return plist_bytes(strings, data)
    return data


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = args.source.resolve(strict=True)
    payload = root / "Payload"
    output = root / "dist" / "TachiBooks-5.0-511-unsigned.ipa"
    report_path = root / "verification" / "repack_verification.json"
    for target in (payload, output, report_path):
        if target.exists():
            raise FileExistsError(f"Refusing to overwrite existing output: {target}")
    original_hash = sha256(source)
    modified = []
    copied = 0
    with zipfile.ZipFile(source) as original:
        entries = original.infolist()
        names = [entry.filename for entry in entries]
        if len(names) != len(set(names)):
            raise ValueError("Duplicate archive paths")
        app_plists = [n for n in names if n.startswith("Payload/")
                      and n.endswith(".app/Info.plist") and n.count("/") == 2]
        if len(app_plists) != 1:
            raise ValueError("Expected exactly one top-level application")
        old_prefix = app_plists[0][:-len("Info.plist")]
        new_prefix = "Payload/TachiBooks.app/"
        original_info = plistlib.loads(original.read(app_plists[0]))
        if (original_info.get("CFBundleShortVersionString"),
                original_info.get("CFBundleVersion")) != ("5.0", "511"):
            raise ValueError("This recipe is scoped to version 5.0 build 511")
        # Validate every destination before creating any payload files.
        for entry in entries:
            path = PurePosixPath(entry.filename)
            mode = entry.external_attr >> 16
            if path.is_absolute() or ".." in path.parts or "\\" in entry.filename:
                raise ValueError(f"Unsafe archive path: {entry.filename}")
            if stat.S_ISLNK(mode):
                raise ValueError(f"Symlink requires a platform-aware extractor: {entry.filename}")
            if entry.filename != "Payload/" and not entry.filename.startswith(old_prefix):
                raise ValueError(f"Unexpected path outside app: {entry.filename}")
        output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output, "x") as result:
            result.comment = original.comment
            for entry in entries:
                name = entry.filename.replace(old_prefix, new_prefix, 1)
                target = root.joinpath(*PurePosixPath(name).parts)
                info = copy.copy(entry)
                info.filename = name
                if entry.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                    result.writestr(info, b"")
                    continue
                data = original.read(entry)
                relative = entry.filename[len(old_prefix):]
                renamed = rename_resource(relative, data)
                if renamed != data:
                    modified.append(name)
                else:
                    copied += 1
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open("xb") as stream:
                    stream.write(renamed)
                result.writestr(info, renamed)

        with zipfile.ZipFile(output) as result:
            assert result.testzip() is None, "Output CRC check failed"
            assert len(result.infolist()) == len(entries), "Entry count changed"
            for entry in entries:
                name = entry.filename.replace(old_prefix, new_prefix, 1)
                if entry.is_dir():
                    continue
                expected = rename_resource(entry.filename[len(old_prefix):], original.read(entry))
                actual = result.read(name)
                assert actual == expected, f"Unexpected content: {name}"
                assert root.joinpath(*PurePosixPath(name).parts).read_bytes() == actual
            current_info = plistlib.loads(result.read(new_prefix + "Info.plist"))
            assert current_info["CFBundleDisplayName"] == "TachiBooks"
            assert current_info["CFBundleIdentifier"] == original_info["CFBundleIdentifier"]
            assert new_prefix + current_info["CFBundleExecutable"] in result.namelist()

    final_source_hash = sha256(source)
    assert final_source_hash == original_hash, "Source IPA changed"
    report = {
        "source_path": str(source),
        "source_sha256_before": original_hash,
        "source_sha256_after": final_source_hash,
        "output_path": str(output),
        "output_sha256": sha256(output),
        "archive_entries": len(entries),
        "byte_identical_files": copied,
        "modified_files": modified,
        "archive_crc_verified": True,
        "payload_matches_output": True,
        "display_name": current_info["CFBundleDisplayName"],
        "bundle_identifier": current_info["CFBundleIdentifier"],
        "version": current_info["CFBundleShortVersionString"],
        "build": current_info["CFBundleVersion"],
        "signing": "Not performed; original embedded signature artifacts retained and not valid for modified resources",
        "ios_runtime_tested": False,
        "source_project_available": False,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with report_path.open("x", encoding="utf-8") as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    print(json.dumps({"output": str(output), "entries": len(entries),
                      "byte_identical_files": copied, "modified_files": len(modified),
                      "sha256": report["output_sha256"]}, indent=2))


if __name__ == "__main__":
    main()
