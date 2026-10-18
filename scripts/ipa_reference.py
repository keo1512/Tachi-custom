"""Read-only, bounded static audit of the original Tachimanga IPA.

No program from the IPA is executed and no archive path is extracted. The
nested Java resource ZIP uses a private temporary seekable spool. Evidence is
published atomically, only to a new, explicitly named JSON file.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import sys
import tempfile
from typing import BinaryIO
import unicodedata
import zipfile
import zlib
from xml.parsers.expat import ExpatError


REFERENCE_SHA256 = "2bbb80719fc4054dd45d223e9478dab76816017e3cedd2f22234f70c7b2e94c5"
CHUNK_SIZE = 1024 * 1024
REPRESENTATIVE_CLASSES = (
    "suwayomi/tachidesk/MainKt.class",
    "suwayomi/tachidesk/manga/impl/extension/Extension.class",
    "suwayomi/tachidesk/manga/impl/Page.class",
    "suwayomi/tachidesk/manga/impl/download/DownloadManager.class",
    "suwayomi/tachidesk/manga/impl/download/ArchiveProvider.class",
    "suwayomi/tachidesk/server/database/DBManager.class",
    "org/tachiyomi/NativeChannel.class",
)
NAMESPACES = ("suwayomi/", "eu/kanade/tachiyomi/", "app/tachimanga/", "org/tachiyomi/")


class AuditError(ValueError):
    """The input or destination cannot produce trustworthy audit evidence."""


@dataclass(frozen=True)
class Limits:
    max_entries: int = 100_000
    max_entry_bytes: int = 512 * 1024 * 1024
    max_total_bytes: int = 2 * 1024 * 1024 * 1024
    max_compression_ratio: int = 1000
    max_central_directory_bytes: int = 64 * 1024 * 1024
    max_plist_bytes: int = 4 * 1024 * 1024
    max_manifest_bytes: int = 1024 * 1024
    max_load_command_bytes: int = 8 * 1024 * 1024
    max_fat_slices: int = 16
    spool_memory_bytes: int = 8 * 1024 * 1024

    def __post_init__(self) -> None:
        if any(value <= 0 for value in vars(self).values()):
            raise AuditError("All resource limits must be positive")


def _read_exact(stream: BinaryIO, size: int, context: str) -> bytes:
    data = stream.read(size)
    if len(data) != size:
        raise AuditError(f"Truncated {context}")
    return data


def _sha256(stream: BinaryIO) -> str:
    digest = hashlib.sha256()
    while chunk := stream.read(CHUNK_SIZE):
        digest.update(chunk)
    return digest.hexdigest()


def _zip_preflight(stream: BinaryIO, limits: Limits, label: str) -> int:
    """Bound the central directory before ZipFile allocates all ZipInfo records.

    Split archives, ZIP64, prepended executables and trailing data are deliberately
    unsupported. They are unnecessary for this reference and add ambiguity.
    """
    stream.seek(0, os.SEEK_END)
    size = stream.tell()
    stream.seek(max(0, size - 65_557))
    tail = stream.read(65_557)
    end = tail.rfind(b"PK\x05\x06")
    while end >= 0:
        if end + 22 <= len(tail):
            values = struct.unpack_from("<4s4H2IH", tail, end)
            if end + 22 + values[-1] == len(tail):
                break
        end = tail.rfind(b"PK\x05\x06", 0, end)
    if end < 0:
        raise AuditError(f"{label}: missing ZIP end record or trailing data")
    _, disk, cd_disk, disk_count, count, cd_size, cd_offset, _ = values
    if disk or cd_disk or disk_count != count:
        raise AuditError(f"{label}: split ZIP archives are unsupported")
    if count == 0xFFFF or cd_size == 0xFFFFFFFF or cd_offset == 0xFFFFFFFF:
        raise AuditError(f"{label}: ZIP64 archives are unsupported")
    if count > limits.max_entries or cd_size > limits.max_central_directory_bytes:
        raise AuditError(f"{label}: central directory exceeds resource limits")
    end_offset = size - len(tail) + end
    if cd_offset + cd_size != end_offset:
        raise AuditError(f"{label}: inconsistent central directory bounds")
    stream.seek(0)
    return count


def _safe_name(info: zipfile.ZipInfo) -> str:
    name = info.orig_filename
    if not name or name != info.filename or "\\" in name or ":" in name:
        raise AuditError(f"Unsafe ZIP path: {name!r}")
    if name.startswith("/") or any(ord(char) < 32 or ord(char) == 127 for char in name):
        raise AuditError(f"Unsafe ZIP path: {name!r}")
    parts = name.rstrip("/").split("/")
    if any(part in ("", ".", "..") or part.endswith((" ", ".")) for part in parts):
        raise AuditError(f"Unsafe or ambiguous ZIP path: {name!r}")
    return unicodedata.normalize("NFC", "/".join(parts)).casefold()


def _validate_entries(archive: zipfile.ZipFile, limits: Limits, label: str) -> list[zipfile.ZipInfo]:
    entries = archive.infolist()
    if len(entries) > limits.max_entries:
        raise AuditError(f"{label}: too many entries")
    names: dict[str, zipfile.ZipInfo] = {}
    total = 0
    intervals = []
    for info in entries:
        key = _safe_name(info)
        if key in names:
            raise AuditError(f"{label}: duplicate or colliding ZIP path: {info.filename!r}")
        names[key] = info
        mode = stat.S_IFMT(info.external_attr >> 16)
        if mode not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise AuditError(f"{label}: symlink or special file is unsupported: {info.filename!r}")
        if mode == stat.S_IFDIR and not info.is_dir():
            raise AuditError(f"{label}: inconsistent directory metadata: {info.filename!r}")
        if mode == stat.S_IFREG and info.is_dir():
            raise AuditError(f"{label}: regular file has a directory path: {info.filename!r}")
        if info.flag_bits & 1:
            raise AuditError(f"{label}: encrypted ZIP entry is unsupported")
        if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            raise AuditError(f"{label}: unsupported ZIP compression")
        if info.is_dir() and info.file_size:
            raise AuditError(f"{label}: directory contains data")
        if info.file_size > limits.max_entry_bytes:
            raise AuditError(f"{label}: entry exceeds size limit: {info.filename!r}")
        if info.file_size > max(1, info.compress_size) * limits.max_compression_ratio:
            raise AuditError(f"{label}: entry exceeds compression-ratio limit: {info.filename!r}")
        if info.header_offset < 0 or info.header_offset >= archive.start_dir:
            raise AuditError(f"{label}: local header is outside ZIP data")
        intervals.append((info.header_offset, info.header_offset + 30 + info.compress_size))
        total += info.file_size
        if total > limits.max_total_bytes:
            raise AuditError(f"{label}: total uncompressed size exceeds limit")
    for key in names:
        parts = key.split("/")
        for length in range(1, len(parts)):
            parent = names.get("/".join(parts[:length]))
            if parent is not None and not parent.is_dir():
                raise AuditError(f"{label}: file/directory path conflict: {parent.filename!r}")
    # ZipFile.open also checks the exact local name, header and overlapping data.
    intervals.sort()
    if any(left[1] > right[0] for left, right in zip(intervals, intervals[1:])):
        raise AuditError(f"{label}: overlapping ZIP entries")
    return entries


def _small_entry(archive: zipfile.ZipFile, name: str, limit: int) -> bytes:
    info = archive.getinfo(name)
    if info.is_dir() or info.file_size > limit:
        raise AuditError(f"Invalid or oversized structured resource: {name!r}")
    with archive.open(info) as stream:
        data = stream.read(limit + 1)
        if len(data) != info.file_size or len(data) > limit:
            raise AuditError(f"Structured resource exceeds declared size: {name!r}")
        return data


def _app_metadata(archive: zipfile.ZipFile, entries: list[zipfile.ZipInfo], limits: Limits) -> dict:
    matches = [info.filename for info in entries if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", info.filename)]
    if len(matches) != 1:
        raise AuditError("IPA must contain exactly one main Payload/*.app/Info.plist")
    try:
        plist = plistlib.loads(_small_entry(archive, matches[0], limits.max_plist_bytes))
    except (plistlib.InvalidFileException, ValueError, TypeError, OverflowError, ExpatError) as error:
        raise AuditError(f"Malformed application plist: {error}") from error
    if not isinstance(plist, dict):
        raise AuditError("Application plist must be a dictionary")
    fields = {
        "bundle_id": "CFBundleIdentifier", "version": "CFBundleShortVersionString",
        "build": "CFBundleVersion", "minimum_ios": "MinimumOSVersion",
        "executable": "CFBundleExecutable",
    }
    metadata = {key: plist.get(field) for key, field in fields.items()}
    if any(not isinstance(value, str) or not value.strip() for value in metadata.values()):
        raise AuditError("Application plist is missing required string metadata")
    if not re.fullmatch(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+", metadata["bundle_id"]):
        raise AuditError("Malformed bundle identifier")
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", metadata["minimum_ios"]):
        raise AuditError("Malformed MinimumOSVersion")
    executable = metadata["executable"]
    if "/" in executable or "\\" in executable or ":" in executable or executable in (".", ".."):
        raise AuditError("Unsafe CFBundleExecutable")
    metadata.update({"info_plist_entry": matches[0], "app_root": matches[0].rsplit("/", 1)[0]})
    return metadata


def _lc_string(command: bytes, offset: int, minimum: int, label: str) -> str:
    if offset < minimum or offset >= len(command):
        raise AuditError(f"Invalid Mach-O {label} string offset")
    end = command.find(b"\0", offset)
    if end < 0:
        raise AuditError(f"Unterminated Mach-O {label}")
    try:
        value = command[offset:end].decode("utf-8")
    except UnicodeDecodeError as error:
        raise AuditError(f"Invalid Mach-O {label} encoding") from error
    if not value or any(ord(char) < 32 for char in value):
        raise AuditError(f"Invalid Mach-O {label}")
    return value


def _macho_slice(stream: BinaryIO, offset: int, size: int, limits: Limits) -> dict:
    stream.seek(offset)
    magic = _read_exact(stream, 4, "Mach-O magic")
    variants = {b"\xcf\xfa\xed\xfe": ("<", True), b"\xce\xfa\xed\xfe": ("<", False),
                b"\xfe\xed\xfa\xcf": (">", True), b"\xfe\xed\xfa\xce": (">", False)}
    if magic not in variants:
        raise AuditError("Invalid Mach-O magic")
    endian, is64 = variants[magic]
    header_size = 32 if is64 else 28
    if size < header_size:
        raise AuditError("Truncated Mach-O header")
    values = struct.unpack(endian + ("7I" if is64 else "6I"), _read_exact(stream, header_size - 4, "Mach-O header"))
    cpu, subtype, file_type, ncmds, command_bytes, flags = values[:6]
    if not 1 <= file_type <= 12 or command_bytes > limits.max_load_command_bytes:
        raise AuditError("Invalid or oversized Mach-O load-command region")
    if header_size + command_bytes > size or ncmds > command_bytes // 8:
        raise AuditError("Mach-O load commands exceed binary bounds")
    commands = _read_exact(stream, command_bytes, "Mach-O load commands")
    paths, rpaths, encryption = [], [], []
    position = 0
    load_types = {0xC: "load", 0xD: "id", 0x18: "weak", 0x1F: "reexport", 0x20: "lazy", 0x23: "upward"}
    for _ in range(ncmds):
        if position + 8 > len(commands):
            raise AuditError("Truncated Mach-O load command")
        command_id, length = struct.unpack_from(endian + "2I", commands, position)
        if length < 8 or length % (8 if is64 else 4) or position + length > len(commands):
            raise AuditError("Invalid Mach-O load-command size")
        command = commands[position:position + length]
        kind = command_id & 0x7FFFFFFF
        if kind in load_types:
            if length < 24:
                raise AuditError("Truncated Mach-O dylib command")
            string_offset = struct.unpack_from(endian + "I", command, 8)[0]
            paths.append({"kind": load_types[kind], "path": _lc_string(command, string_offset, 24, "dylib path")})
        elif kind == 0x1C:
            if length < 12:
                raise AuditError("Truncated Mach-O rpath command")
            string_offset = struct.unpack_from(endian + "I", command, 8)[0]
            rpaths.append(_lc_string(command, string_offset, 12, "rpath"))
        elif kind in (0x21, 0x2C):
            if length < (24 if kind == 0x2C else 20):
                raise AuditError("Truncated Mach-O encryption command")
            start, count, cryptid = struct.unpack_from(endian + "3I", command, 8)
            if start + count > size:
                raise AuditError("Mach-O encryption range exceeds binary")
            encryption.append({"offset": start, "size_bytes": count, "cryptid": cryptid})
        elif kind in (0x1, 0x19):
            segment64 = kind == 0x19
            base, section_size = (72, 80) if segment64 else (56, 68)
            if length < base:
                raise AuditError("Truncated Mach-O segment command")
            fileoff, filesize = struct.unpack_from(endian + ("2Q" if segment64 else "2I"), command, 40 if segment64 else 32)
            sections = struct.unpack_from(endian + "I", command, 64 if segment64 else 48)[0]
            if length != base + section_size * sections or fileoff + filesize > size:
                raise AuditError("Invalid Mach-O segment bounds")
        elif kind == 0x1D:
            if length < 16:
                raise AuditError("Truncated Mach-O code-signature command")
            start, count = struct.unpack_from(endian + "2I", command, 8)
            if start + count > size:
                raise AuditError("Mach-O code-signature range exceeds binary")
        position += length
    if position != len(commands):
        raise AuditError("Mach-O command count does not consume declared region")
    architectures = {0x0100000C: "arm64", 12: "arm", 0x01000007: "x86_64", 7: "x86"}
    return {"architecture": architectures.get(cpu, f"cpu_0x{cpu:08x}"), "cpu_type": cpu,
            "cpu_subtype": subtype, "is_64_bit": is64, "byte_order": "little" if endian == "<" else "big",
            "file_type": file_type, "flags": flags, "offset": offset, "size_bytes": size,
            "load_command_count": ncmds, "dylib_paths": paths, "rpaths": rpaths,
            "encryption_commands": encryption, "encrypted": any(item["cryptid"] for item in encryption) != 0}


def parse_macho(stream: BinaryIO, size: int, limits: Limits) -> dict:
    """Validate thin/fat headers and bounded load commands without executing code."""
    stream.seek(0)
    magic = _read_exact(stream, 4, "Mach-O magic")
    fat_variants = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
                    b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    if magic not in fat_variants:
        slices = [_macho_slice(stream, 0, size, limits)]
    else:
        endian, fat64 = fat_variants[magic]
        count = struct.unpack(endian + "I", _read_exact(stream, 4, "fat Mach-O header"))[0]
        entry_size = 32 if fat64 else 20
        if not 1 <= count <= limits.max_fat_slices or 8 + count * entry_size > size:
            raise AuditError("Invalid fat Mach-O architecture table")
        table = _read_exact(stream, count * entry_size, "fat Mach-O architecture table")
        intervals, records, seen_cpus = [], [], set()
        for index in range(count):
            values = struct.unpack_from(endian + ("2I2Q2I" if fat64 else "5I"), table, index * entry_size)
            cpu, subtype, start, length, align = values[:5]
            if ((cpu, subtype) in seen_cpus or align > 31 or start % (1 << align)
                    or start < 8 + count * entry_size or not length or start + length > size):
                raise AuditError("Invalid fat Mach-O slice bounds or duplicate architecture")
            seen_cpus.add((cpu, subtype))
            intervals.append((start, start + length))
            records.append((cpu, subtype, start, length))
        intervals.sort()
        if any(left[1] > right[0] for left, right in zip(intervals, intervals[1:])):
            raise AuditError("Overlapping fat Mach-O slices")
        slices = []
        for cpu, subtype, start, length in records:
            item = _macho_slice(stream, start, length, limits)
            if item["cpu_type"] != cpu or item["cpu_subtype"] != subtype:
                raise AuditError("Fat Mach-O CPU metadata disagrees with slice")
            slices.append(item)
    return {"architectures": [item["architecture"] for item in slices], "slices": slices,
            "encrypted": any(item["encrypted"] for item in slices)}


def _inventory(archive: zipfile.ZipFile, entries: list[zipfile.ZipInfo], limits: Limits,
               *, backend: bool = False, spool_entry: str | None = None,
               spool: BinaryIO | None = None) -> dict:
    files, versions, top_namespaces = [], Counter(), Counter()
    counts = dict.fromkeys(NAMESPACES, 0)
    class_count = 0
    representatives = {}
    manifests = []
    actual_total = 0
    for info in entries:
        digest, prefix, captured, actual = hashlib.sha256(), b"", bytearray(), 0
        manifest = backend and (info.filename.upper().endswith("/MANIFEST.MF") or info.filename.upper() == "MANIFEST.MF")
        if manifest and info.file_size > limits.max_manifest_bytes:
            raise AuditError("Nested manifest exceeds size limit")
        with archive.open(info) as stream:
            while chunk := stream.read(CHUNK_SIZE):
                actual += len(chunk)
                actual_total += len(chunk)
                if actual > info.file_size or actual > limits.max_entry_bytes or actual_total > limits.max_total_bytes:
                    raise AuditError("Streamed ZIP data exceeds declared size or resource limit")
                digest.update(chunk)
                if len(prefix) < 10:
                    prefix += chunk[:10 - len(prefix)]
                if manifest:
                    captured.extend(chunk)
                if info.filename == spool_entry:
                    if spool is None:
                        raise AuditError("Missing nested ZIP spool")
                    spool.write(chunk)
        if actual != info.file_size:
            raise AuditError(f"ZIP entry has inconsistent uncompressed size: {info.filename!r}")
        hashed = digest.hexdigest() if not info.is_dir() else None
        files.append({"path": info.filename, "is_directory": info.is_dir(), "sha256": hashed,
                      "size_bytes": actual, "compressed_size_bytes": info.compress_size,
                      "crc32": f"{info.CRC:08x}", "compression_method": info.compress_type,
                      "flags": info.flag_bits, "create_system": info.create_system,
                      "external_attributes": info.external_attr, "local_header_offset": info.header_offset,
                      "zip_timestamp": list(info.date_time)})
        if backend and not info.is_dir() and info.filename.endswith(".class"):
            if len(prefix) != 10 or prefix[:4] != b"\xca\xfe\xba\xbe":
                raise AuditError(f"Invalid Java class header: {info.filename!r}")
            minor, major, constant_pool_count = struct.unpack(">3H", prefix[4:])
            if not 45 <= major <= 100 or constant_pool_count == 0:
                raise AuditError(f"Invalid Java class version or constant-pool header: {info.filename!r}")
            class_count += 1
            versions[f"{major}.{minor}"] += 1
            top_namespaces[info.filename.split("/", 1)[0]] += 1
            for namespace in counts:
                if info.filename.startswith(namespace):
                    counts[namespace] += 1
            if info.filename in REPRESENTATIVE_CLASSES:
                representatives[info.filename] = hashed
        if manifest:
            manifests.append({"path": info.filename, "sha256": hashed, **_parse_manifest(bytes(captured))})
    result = {"entry_count": len(entries), "file_count": sum(not info.is_dir() for info in entries),
              "directory_count": sum(info.is_dir() for info in entries), "uncompressed_size_bytes": actual_total,
              "crc_checked_for_all_entries": True, "inventory": files}
    if backend:
        result.update({"class_count": class_count, "class_namespace_counts": counts,
                       "top_level_class_namespace_counts": dict(sorted(top_namespaces.items())),
                       "class_version_counts": dict(sorted(versions.items())), "manifests": manifests,
                       "representative_class_sha256": representatives,
                       "representative_classes_missing": [name for name in REPRESENTATIVE_CLASSES if name not in representatives]})
    return result


def _parse_manifest(data: bytes) -> dict:
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise AuditError("Nested manifest is not UTF-8") from error
    if "\x00" in text:
        raise AuditError("Nested manifest contains NUL")
    sections: list[dict[str, str]] = [{}]
    previous = None
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if not line:
            if sections[-1]:
                sections.append({})
            previous = None
        elif line.startswith(" "):
            if previous is None:
                raise AuditError("Invalid manifest continuation")
            sections[-1][previous] += line[1:]
        else:
            if ": " not in line:
                raise AuditError("Malformed manifest attribute")
            key, value = line.split(": ", 1)
            if not re.fullmatch(r"[A-Za-z0-9_-]+", key) or key.casefold() in {item.casefold() for item in sections[-1]}:
                raise AuditError("Duplicate or malformed manifest key")
            sections[-1][key] = value
            previous = key
    sections = [section for section in sections if section]
    return {"main_attributes": sections[0] if sections else {}, "additional_sections": sections[1:]}


def _signature(path: Path) -> tuple:
    metadata = path.stat()
    return metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns, metadata.st_ctime_ns


def audit_ipa(source: Path | str, *, strict_reference: bool = False, limits: Limits | None = None) -> dict:
    """Return evidence; leave source, prior payloads and prior outputs untouched."""
    limits = limits or Limits()
    source = Path(source).resolve(strict=True)
    if not source.is_file():
        raise AuditError("IPA source must be a regular file")
    before = _signature(source)
    try:
        with source.open("rb") as stream:
            initial_hash = _sha256(stream)
            if strict_reference and initial_hash != REFERENCE_SHA256:
                raise AuditError("Source SHA-256 does not match pinned original Tachimanga IPA")
            declared_entries = _zip_preflight(stream, limits, "IPA")
            with zipfile.ZipFile(stream) as archive:
                entries = _validate_entries(archive, limits, "IPA")
                if declared_entries != len(entries):
                    raise AuditError("IPA: central-directory entry count disagrees with end record")
                metadata = _app_metadata(archive, entries, limits)
                root = metadata["app_root"]
                binary_paths = {"main": root + "/" + metadata["executable"],
                                "flutter_app": root + "/Frameworks/App.framework/App"}
                nested_path = root + "/MCHome.bundle/res.zip"
                names = {info.filename: info for info in entries}
                for name in (*binary_paths.values(), nested_path):
                    if name not in names or names[name].is_dir():
                        raise AuditError(f"Required reference resource is missing: {name}")
                if strict_reference and (metadata["version"], metadata["build"], metadata["bundle_id"], metadata["minimum_ios"]) != ("5.0", "511", "com.mangacrush.ios", "15.0"):
                    raise AuditError("Pinned IPA has unexpected reference metadata")
                binaries = {}
                for role, name in binary_paths.items():
                    with archive.open(name) as binary:
                        binaries[role] = {"entry": name, **parse_macho(binary, names[name].file_size, limits)}
                    expected_type = 2 if role == "main" else 6
                    if any(item["file_type"] != expected_type for item in binaries[role]["slices"]):
                        raise AuditError(f"Unexpected Mach-O file type for {role}")
                with tempfile.SpooledTemporaryFile(max_size=limits.spool_memory_bytes, mode="w+b") as spool:
                    outer = _inventory(archive, entries, limits, spool_entry=nested_path, spool=spool)
                    declared_nested_entries = _zip_preflight(spool, limits, "res.zip")
                    with zipfile.ZipFile(spool) as backend:
                        nested_entries = _validate_entries(backend, limits, "res.zip")
                        if declared_nested_entries != len(nested_entries):
                            raise AuditError("res.zip: central-directory entry count disagrees with end record")
                        nested = _inventory(backend, nested_entries, limits, backend=True)
                    nested["entry"] = nested_path
                    nested["sha256"] = next(item["sha256"] for item in outer["inventory"] if item["path"] == nested_path)
            stream.seek(0)
            final_hash = _sha256(stream)
        if initial_hash != final_hash or before != _signature(source):
            raise AuditError("Source changed during audit; evidence was discarded")
    except (zipfile.BadZipFile, zipfile.LargeZipFile, RuntimeError, EOFError, struct.error, zlib.error) as error:
        raise AuditError(f"Invalid archive or binary structure: {error}") from error
    return {"schema_version": 1, "audit_type": "immutable_ipa_reference_static",
            "created_at_utc": datetime.now(timezone.utc).isoformat(),
            "source": {"path": str(source), "size_bytes": before[2], "sha256_before": initial_hash,
                       "sha256_after": final_hash, "unchanged_during_audit": True,
                       "strict_reference_requested": strict_reference, "matches_pinned_reference": initial_hash == REFERENCE_SHA256},
            "limits": vars(limits), "app": metadata, "ipa": outer, "binaries": binaries, "backend": nested,
            "runtime": {"verified": False, "note": "Static audit only; installation, startup, UI parity, engine behavior and device stability are unverified."},
            "limitations": ["Java class validation covers headers only, not bytecode correctness or recovered source.",
                            "Mach-O inspection validates headers/load-command bounds; it does not validate executable instructions, signatures or runtime behavior.",
                            "ZIP64, split archives, ZIP symlinks and compression other than stored/deflate are unsupported."]}


def _output_destination(source: Path, output: Path | str) -> Path:
    requested = Path(output).absolute()
    if requested.suffix.lower() != ".json":
        raise AuditError("Evidence output must explicitly name a new .json file")
    if requested.exists() or requested.is_symlink():
        raise AuditError("Refusing to overwrite an existing file or symbolic link")
    parent = requested.parent.resolve(strict=True)
    if not parent.is_dir():
        raise AuditError("Evidence parent must be an existing directory")
    destination = parent / requested.name
    if destination == source.resolve(strict=True):
        raise AuditError("Evidence must not overwrite the reference source")
    return destination


def write_evidence(source: Path | str, output: Path | str, *, strict_reference: bool = False,
                   limits: Limits | None = None) -> dict:
    """Audit first, then atomically create evidence without replacing any file."""
    source = Path(source)
    destination = _output_destination(source, output)
    evidence = audit_ipa(source, strict_reference=strict_reference, limits=limits)
    descriptor, temporary = tempfile.mkstemp(prefix=".ipa-reference-", suffix=".tmp", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(evidence, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        # A same-directory hard link publishes an entire file atomically and
        # fails if another writer created the destination during the audit.
        os.link(temporary, destination)
    except FileExistsError as error:
        raise AuditError("Evidence destination appeared during audit; refusing overwrite") from error
    finally:
        os.unlink(temporary)
    return evidence


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Original IPA; opened read-only")
    parser.add_argument("--output", type=Path, required=True, help="New JSON evidence file; parent must already exist")
    parser.add_argument("--strict-reference", action="store_true", help="Require pinned original SHA-256 and 5.0 build 511 metadata")
    args = parser.parse_args(argv)
    try:
        evidence = write_evidence(args.source, args.output, strict_reference=args.strict_reference)
    except (AuditError, OSError, ValueError) as error:
        print(f"Audit failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"evidence": str(args.output.resolve()), "source_sha256": evidence["source"]["sha256_before"],
                      "entries": evidence["ipa"]["entry_count"], "java_classes": evidence["backend"]["class_count"],
                      "runtime_verified": False}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
