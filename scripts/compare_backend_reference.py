"""Compare public backend dependencies and contracts with an original IPA.

Read-only inspection: no files are extracted, executed, signed or modified. Byte
identity of bundled dependency classes is distinguished from source equivalence
and from runtime acceptance. Uses only Python's standard library.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import tempfile
import zipfile


PINNED_COMMIT = "2e52214106ffab02d13ff61a620def78414a8a45"
PINNED_IPA_SHA256 = "2bbb80719fc4054dd45d223e9478dab76816017e3cedd2f22234f70c7b2e94c5"
DEPENDENCIES = (
    "libs/android.jar",
    "libs/sqlite-jdbc-ios-3.41.0.0.jar",
    "libs/cloud-api-1.0.0.jar",
)
NATIVE_CONTRACTS = {
    "org/tachiyomi/NativeChannel.class": ("call_utf8", "([B[B)V"),
    "org/tachiyomi/NativeNet.class": ("call_utf8", "([BLokio/Buffer;)[[B"),
    "org/tachiyomi/NativeString.class": (
        "indexOf", "(Ljava/lang/String;Ljava/lang/String;)I"
    ),
}
SELECTED_CLASSES = (
    *NATIVE_CONTRACTS,
    "android/graphics/Bitmap.class",
    "android/webkit/McCookieManager.class",
    "android/webkit/WebView.class",
    "app/cash/quickjs/QuickJs.class",
    "android/database/sqlite/SQLiteDebug.class",
    "android/database/sqlite/SQLiteGlobal.class",
    "android/os/Process.class",
    "org/sqlite/core/NativeDB.class",
    "org/sqlite/SQLiteJDBCLoader.class",
    "suwayomi/tachidesk/MainKt.class",
    "suwayomi/tachidesk/manga/model/table/MangaTable.class",
    "suwayomi/tachidesk/manga/model/table/MangaTableKt.class",
    "suwayomi/tachidesk/manga/model/table/ChapterTable.class",
    "suwayomi/tachidesk/manga/model/table/ChapterTableKt.class",
    "suwayomi/tachidesk/manga/impl/util/PackageTools.class",
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def unique_entries(archive: zipfile.ZipFile) -> dict[str, zipfile.ZipInfo]:
    """Reject ambiguous archives instead of silently choosing the last entry."""
    entries: dict[str, zipfile.ZipInfo] = {}
    for entry in archive.infolist():
        if entry.filename in entries:
            raise ValueError(f"Duplicate archive entry: {entry.filename}")
        entries[entry.filename] = entry
    return entries


def compare_classes(
    dependency: zipfile.ZipFile, reference: zipfile.ZipFile
) -> dict:
    source_entries = unique_entries(dependency)
    reference_entries = unique_entries(reference)
    inventory = []
    differences = []
    versions: Counter[int] = Counter()
    counts: Counter[str] = Counter()
    for name in sorted(n for n in source_entries if n.endswith(".class")):
        source = dependency.read(source_entries[name])
        source_sha = digest(source)
        if len(source) >= 8 and source[:4] == b"\xca\xfe\xba\xbe":
            versions[struct.unpack(">H", source[6:8])[0]] += 1
        reference_sha = (
            digest(reference.read(reference_entries[name]))
            if name in reference_entries else None
        )
        status = (
            "missing_in_ipa" if reference_sha is None
            else "byte_identical" if source_sha == reference_sha
            else "different_bytes"
        )
        record = {
            "class": name,
            "dependency_sha256": source_sha,
            "ipa_sha256": reference_sha,
            "result": status,
        }
        inventory.append(record)
        counts[status] += 1
        if status != "byte_identical":
            differences.append(record)
    # A compact, deterministic fingerprint of every compared class and hash.
    encoded = json.dumps(inventory, ensure_ascii=True, sort_keys=True,
                         separators=(",", ":")).encode("ascii")
    return {
        "class_count": len(inventory),
        "byte_identical": counts["byte_identical"],
        "different_bytes": counts["different_bytes"],
        "missing_in_ipa": counts["missing_in_ipa"],
        "classfile_major_versions": dict(sorted(versions.items())),
        "class_inventory_sha256": digest(encoded),
        "differences": differences,
    }


class ClassReader:
    """Minimal JVM classfile reader; records signatures, not decompiled logic."""

    def __init__(self, data: bytes):
        self.data = data
        self.offset = 0

    def take(self, length: int) -> bytes:
        if length < 0 or self.offset + length > len(self.data):
            raise ValueError("Truncated JVM classfile")
        result = self.data[self.offset:self.offset + length]
        self.offset += length
        return result

    def number(self, size: int) -> int:
        return int.from_bytes(self.take(size), "big")

    def parse(self) -> dict:
        if self.take(4) != b"\xca\xfe\xba\xbe":
            raise ValueError("Invalid JVM classfile magic")
        minor, major = self.number(2), self.number(2)
        pool: list[tuple | None] = [None] * self.number(2)
        index = 1
        while index < len(pool):
            tag = self.number(1)
            if tag == 1:
                # Names/descriptors here are ASCII; modified UTF8 in arbitrary
                # string literals is intentionally not interpreted as source.
                pool[index] = (tag, self.take(self.number(2)).decode(
                    "utf-8", errors="replace"))
            elif tag in (3, 4):
                pool[index] = (tag, self.take(4))
            elif tag in (5, 6):
                pool[index] = (tag, self.take(8))
                index += 1
            elif tag in (7, 8, 16, 19, 20):
                pool[index] = (tag, self.number(2))
            elif tag in (9, 10, 11, 12, 17, 18):
                pool[index] = (tag, self.number(2), self.number(2))
            elif tag == 15:
                pool[index] = (tag, self.number(1), self.number(2))
            else:
                raise ValueError(f"Unsupported JVM constant-pool tag: {tag}")
            index += 1

        def utf8(cp_index: int) -> str:
            if not 0 < cp_index < len(pool):
                raise ValueError("Invalid constant-pool index")
            item = pool[cp_index]
            if item is None or item[0] != 1:
                raise ValueError("Expected constant-pool UTF8 entry")
            return item[1]

        def attributes() -> dict:
            result = {}
            for _ in range(self.number(2)):
                name = utf8(self.number(2))
                value = self.take(self.number(4))
                if name == "Code":
                    result["code_attribute_sha256"] = digest(value)
                elif name == "Signature":
                    if len(value) != 2:
                        raise ValueError("Invalid JVM Signature attribute")
                    result["generic_signature"] = utf8(int.from_bytes(value, "big"))
                elif name == "SourceFile":
                    if len(value) != 2:
                        raise ValueError("Invalid JVM SourceFile attribute")
                    result["source_file"] = utf8(int.from_bytes(value, "big"))
            return result

        access = self.number(2)
        this_class, super_class = self.number(2), self.number(2)
        if (not 0 < this_class < len(pool) or pool[this_class] is None
                or pool[this_class][0] != 7):
            raise ValueError("Invalid JVM class name index")
        class_name = utf8(pool[this_class][1])
        self.take(self.number(2) * 2)  # interfaces

        def members() -> list[dict]:
            result = []
            for _ in range(self.number(2)):
                flags = self.number(2)
                result.append({
                    "name": utf8(self.number(2)),
                    "descriptor": utf8(self.number(2)),
                    "access_flags": flags,
                    "public": bool(flags & 0x0001),
                    "static": bool(flags & 0x0008),
                    "native": bool(flags & 0x0100),
                    **attributes(),
                })
            return result

        fields, methods = members(), members()
        class_attributes = attributes()
        if self.offset != len(self.data):
            raise ValueError("Trailing bytes after JVM classfile")
        return {
            "class": class_name,
            "minor_version": minor,
            "major_version": major,
            "access_flags": access,
            "super_class_pool_index": super_class,
            "fields": fields,
            "methods": methods,
            **class_attributes,
        }


def source_for_class(engine: Path, name: str) -> list[str]:
    top_level_name = name.split("$", 1)[0].removesuffix(".class")
    found = []
    for module in ("AndroidCompat", "server"):
        for language, suffix in (("java", ".java"), ("kotlin", ".kt")):
            candidates = [top_level_name]
            if language == "kotlin" and top_level_name.endswith("Kt"):
                candidates.append(top_level_name.removesuffix("Kt"))
            for candidate in candidates:
                path = engine / module / "src/main" / language / (candidate + suffix)
                if path.is_file():
                    found.append(path.relative_to(engine).as_posix())
    return found


def source_properties(engine: Path, name: str, parsed: dict) -> dict:
    """Record source declarations and getter presence without claiming parity."""
    paths = source_for_class(engine, name)
    methods = {m["name"] for m in parsed["methods"]}
    declarations = []
    for path in paths:
        for number, line in enumerate((engine / path).read_text(
                encoding="utf-8").splitlines(), 1):
            match = re.search(r'\bval\s+(\w+)\s*=\s*(\w+)\("([^\"]+)"', line)
            if not match:
                continue
            prop, builder, column = match.groups()
            getter = "get" + prop[0].upper() + prop[1:]
            candidates = [getter, prop] if prop.startswith("is") else [getter]
            declarations.append({
                "source": path,
                "line": number,
                "property": prop,
                "builder": builder,
                "column_literal": column,
                "ipa_getters_observed": [m for m in candidates if m in methods],
            })
    return {
        "source_files": paths,
        "source_file_fingerprints": [
            {"path": path, "sha256": file_digest(engine / path)} for path in paths
        ],
        "source_property_declarations": declarations,
        "limitation": "Getter names and JVM signatures do not prove SQL schema, "
                      "migration or method-body equivalence with this source.",
    }


def verify_source_manifest(engine: Path, path: Path) -> dict:
    """Check tracked input bytes against the saved upstream provenance manifest."""
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if (manifest.get("commit") != PINNED_COMMIT
            or manifest.get("repository") != "https://github.com/tachimanga/Tachidesk-Server"):
        raise ValueError("Unexpected source manifest repository/commit")
    entries = manifest.get("files", [])
    if not entries:
        raise ValueError("Source manifest has no tracked files")
    seen = set()
    engine = engine.resolve(strict=True)
    for entry in entries:
        name = entry["path"]
        if name in seen:
            raise ValueError(f"Duplicate source manifest path: {name}")
        seen.add(name)
        target = (engine / name).resolve()
        if not target.is_relative_to(engine):
            raise ValueError(f"Source manifest path leaves engine directory: {name}")
        if not target.is_file():
            raise ValueError(f"Source manifest file missing: {name}")
        if file_digest(target) != entry["sha256"]:
            raise ValueError(f"Source manifest hash differs: {name}")
    return {
        "manifest_path": str(path.resolve()),
        "manifest_sha256": file_digest(path),
        "declared_commit": manifest["commit"],
        "tracked_files_checked": len(entries),
        "all_tracked_file_hashes_match": True,
        "limitation": "Checks the saved local provenance manifest and tracked file "
                      "bytes; does not independently refetch GitHub or validate "
                      "untracked Gradle build/cache files.",
    }


def build_report(ipa_path: Path, engine: Path,
                 source_manifest: Path | None = None,
                 expected_ipa_sha256: str | None = PINNED_IPA_SHA256) -> dict:
    original_sha = file_digest(ipa_path)
    if expected_ipa_sha256 is not None and original_sha != expected_ipa_sha256:
        raise ValueError("IPA SHA-256 does not match the explicitly selected reference")
    provenance = (
        verify_source_manifest(engine, source_manifest) if source_manifest
        else {"all_tracked_file_hashes_match": None,
              "limitation": "Source tree commit was not verified; only individual "
                            "inspected input hashes identify this comparison."}
    )
    with zipfile.ZipFile(ipa_path) as ipa:
        entries = unique_entries(ipa)
        res_names = [n for n in entries if n.startswith("Payload/")
                     and n.endswith("/MCHome.bundle/res.zip")]
        if len(res_names) != 1:
            raise ValueError(f"Expected one original backend res.zip, found {len(res_names)}")
        res_path = res_names[0]
        app_root = res_path.removesuffix("MCHome.bundle/res.zip")
        metadata = plistlib.loads(ipa.read(app_root + "Info.plist"))
        corrupt = ipa.testzip()
        if corrupt is not None:
            raise ValueError(f"IPA CRC failed: {corrupt}")
        res_bytes = ipa.read(entries[res_path])

    with zipfile.ZipFile(io.BytesIO(res_bytes)) as reference:
        reference_entries = unique_entries(reference)
        corrupt = reference.testzip()
        if corrupt is not None:
            raise ValueError(f"Backend ZIP CRC failed: {corrupt}")
        dependencies = []
        for relative in DEPENDENCIES:
            path = engine / relative
            jar_bytes = path.read_bytes()
            with zipfile.ZipFile(io.BytesIO(jar_bytes)) as jar:
                result = compare_classes(jar, reference)
            for difference in result["differences"]:
                difference["public_source_candidates"] = source_for_class(
                    engine, difference["class"])
            dependencies.append({"path": relative,
                                 "jar_sha256": digest(jar_bytes), **result})

        selected = []
        for name in SELECTED_CLASSES:
            if name not in reference_entries:
                selected.append({"entry": name, "result": "missing_in_ipa"})
                continue
            raw = reference.read(reference_entries[name])
            parsed = ClassReader(raw).parse()
            item = {"entry": name, "sha256": digest(raw), **parsed,
                    **source_properties(engine, name, parsed)}
            if name in NATIVE_CONTRACTS:
                method, descriptor = NATIVE_CONTRACTS[name]
                item["native_contract_check"] = {
                    "expected_name": method,
                    "expected_descriptor": descriptor,
                    "matched": any(m["name"] == method
                                   and m["descriptor"] == descriptor
                                   and m["native"] for m in parsed["methods"]),
                    "limitation": "Declaration only; no native implementation tested.",
                }
            selected.append(item)
    final_sha = file_digest(ipa_path)
    if final_sha != original_sha:
        raise ValueError("Original IPA changed during read-only comparison")
    if source_manifest is not None:
        # A comparison can outlive an editor/save or dependency build. The
        # initial manifest check alone must not label a later changed checkout
        # as verified. Recheck every tracked byte and the manifest itself before
        # publishing a result tied to that pinned source reference.
        final_provenance = verify_source_manifest(engine, source_manifest)
        if final_provenance["manifest_sha256"] != provenance["manifest_sha256"]:
            raise ValueError("Source manifest changed during read-only comparison")
        provenance["unchanged_during_comparison"] = True
    return {
        "schema_version": 1,
        "evidence_type": "static_archive_and_jvm_classfile_comparison",
        "source_reference": {
            "repository": "https://github.com/tachimanga/Tachidesk-Server",
            "expected_commit": PINNED_COMMIT,
            "engine_path": str(engine.resolve()),
            "commit_verification": provenance,
        },
        "ipa_reference": {
            "path": str(ipa_path.resolve()),
            "sha256_before": original_sha,
            "expected_sha256": expected_ipa_sha256,
            "matches_expected_sha256": original_sha == expected_ipa_sha256
                                       if expected_ipa_sha256 is not None else None,
            "sha256_after": final_sha,
            "unchanged": True,
            "version": metadata.get("CFBundleShortVersionString"),
            "build": metadata.get("CFBundleVersion"),
            "bundle_id": metadata.get("CFBundleIdentifier"),
            "backend_entry": res_path,
            "backend_sha256": digest(res_bytes),
            "ipa_crc_valid": True,
            "backend_crc_valid": True,
        },
        "dependency_comparisons": dependencies,
        "selected_ipa_class_contracts": selected,
        "limitations": [
            "Byte-identical dependency classes do not prove public engine source "
            "matches every method in the IPA.",
            "Source candidates beside changed Android classes are evidence of "
            "available source paths, not proof those sources produced IPA bytes.",
            "Model declarations/getter signatures are not complete SQL/migration parity.",
            "Native declarations do not provide JNI implementations, iOS runtime "
            "source, build recipe or device execution evidence.",
            "No Flutter/UI reconstruction, tracker removal, host build or iPhone "
            "runtime acceptance is established by this report.",
        ],
    }


def write_json_atomic(path: Path, value: dict) -> None:
    """Publish a complete report; preserve an earlier report on write failure."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--engine", type=Path, default=root / "engine")
    parser.add_argument("--source-manifest", type=Path,
                        default=root / "verification/upstream_source_manifest.json")
    parser.add_argument("--expected-ipa-sha256", default=PINNED_IPA_SHA256,
                        help="Explicit reference SHA-256; defaults to original 5.0 build 511.")
    parser.add_argument("--output", type=Path,
                        default=root / "verification/backend_reference_comparison.json")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-fA-F]{64}", args.expected_ipa_sha256):
        parser.error("Expected IPA SHA-256 must contain exactly 64 hexadecimal digits")
    inputs = [args.ipa.resolve(), args.source_manifest.resolve(),
              *(args.engine / n for n in DEPENDENCIES)]
    if args.output.resolve() in (p.resolve() for p in inputs):
        parser.error("Output must not overwrite an input")
    if args.output.resolve().is_relative_to(args.engine.resolve()):
        parser.error("Output must not modify the backend source tree")
    report = build_report(args.ipa.resolve(strict=True), args.engine.resolve(strict=True),
                          args.source_manifest.resolve(strict=True),
                          args.expected_ipa_sha256.lower())
    write_json_atomic(args.output, report)
    print(json.dumps({
        "report": str(args.output.resolve()),
        "ipa_unchanged": report["ipa_reference"]["unchanged"],
        "dependencies": [{k: d[k] for k in (
            "path", "class_count", "byte_identical", "different_bytes", "missing_in_ipa"
        )} for d in report["dependency_comparisons"]],
        "selected_class_count": len(report["selected_ipa_class_contracts"]),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
