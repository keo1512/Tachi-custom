#!/usr/bin/env python3
"""Inspect an IPA and its embedded backend without executing or extracting it.

Uses only Python's standard library. Full CRC checks, hashes and byte-level
parsers provide static evidence; this tool does not establish iOS runtime or
extension compatibility. Output intentionally omits credential/config plist
blobs, entitlements and arbitrary binary contents.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import io
import json
from pathlib import Path
import plistlib
import re
import struct
import sys
import zipfile


class InspectionError(Exception):
    """An input is ambiguous, malformed, or cannot be inspected safely."""


SOURCE_SUFFIXES = {
    ".dart", ".kt", ".java", ".swift", ".m", ".mm", ".h", ".hpp",
    ".c", ".cpp", ".cc", ".swiftinterface", ".swiftmodule",
}
BUILD_MARKERS = {
    "pubspec.yaml", "pubspec.lock", "package.swift", "project.pbxproj",
    "kernel_blob.bin", "isolate_snapshot_data", "vm_snapshot_data",
}
INFO_FIELDS = (
    "CFBundleDisplayName", "CFBundleName", "CFBundleIdentifier",
    "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion",
    "CFBundlePackageType", "CFBundleSupportedPlatforms", "MinimumOSVersion",
    "UIDeviceFamily", "DTPlatformName", "DTPlatformVersion", "DTSDKName",
    "DTXcode", "DTXcodeBuild", "CFBundleURLTypes", "CFBundleDocumentTypes",
    "CFBundleLocalizations", "FLTEnableImpeller", "FLTUseFlutterMetalLayer",
    "UIFileSharingEnabled", "UISupportsDocumentBrowser",
)
ENGINE_CLASSES = (
    "suwayomi/tachidesk/MainKt.class",
    "suwayomi/tachidesk/server/BuildConfig.class",
    "suwayomi/tachidesk/server/JavalinSetup.class",
    "suwayomi/tachidesk/manga/MangaAPI.class",
    "suwayomi/tachidesk/manga/impl/JavaChannel.class",
    "suwayomi/tachidesk/manga/impl/extension/Extension.class",
    "suwayomi/tachidesk/manga/controller/ExtensionController.class",
    "eu/kanade/tachiyomi/source/Source.class",
    "eu/kanade/tachiyomi/source/SourceFactory.class",
    "eu/kanade/tachiyomi/source/online/HttpSource.class",
    "mihon/data/extension/service/ExtensionStoreService.class",
    "app/cash/quickjs/QuickJs.class",
)
ENGINE_CONSTANT_PATTERN = re.compile(
    r"MainKt|Tachidesk|suwayomi/|tachiyomi/|mihon/|quickjs/|androidcompat/|"
    r"^main$|^main0$|^startServer$|^stopServer$|^startSocket$|^stopSocket$|"
    r"^waitRequestDone$|^getStatus$|^javaChannel$|^getPipStatusString$|"
    r"^UPDATE:|^DOWNLOAD:|^SERVER:|^PIP:|apk|dex2jar|jar|"
    r"^install|^uninstall|^loadExtension|^createSources$|^parseApk|"
    r"^prepareJar|^getJar|^removeJar|^extractAssets|"
    r"only versions|not a Tachiyomi|^versionName$|^libVersion$|"
    r"^sourceClass$|^sources$|^extensionId$|^pkgName$|"
    r"^getList$|^getInstall|^getUpdate$|^getUninstall$|^getIcon$|"
    r"^v\d|^r\d+$|^Preview$|^https://github.com/|^addEndpoints$|"
    r"^server\.ip$|^server\.port$",
    re.IGNORECASE,
)
BOOTSTRAP_PATTERN = re.compile(
    r"^(?:_?JNI_CreateJavaVM|_?JNI_GetCreatedJavaVMs|_?JNI_GetDefaultJavaVMInitArgs|"
    r"MCBackendPlugin|MCFlutterPlugin|MCNativeChannelPlugin|MCDatabasePlugin|"
    r"MCStoragePlugin|MCBackupPlugin|MCContinuedTaskPlugin|MCDownloadPlugin|"
    r"javaChannel(?::content:)?|MCHome\.bundle|suwayomi/tachidesk/MainKt)$|"
    r"^[-+]\[(?:MCBackendPlugin|MCNativeChannelPlugin|MCFlutterPlugin)\b"
)
LOAD_COMMAND_NAMES = {
    0x1: "LC_SEGMENT", 0x2: "LC_SYMTAB", 0xB: "LC_DYSYMTAB",
    0xC: "LC_LOAD_DYLIB", 0xD: "LC_ID_DYLIB", 0xE: "LC_LOAD_DYLINKER",
    0xF: "LC_ID_DYLINKER", 0x19: "LC_SEGMENT_64", 0x1B: "LC_UUID",
    0x1D: "LC_CODE_SIGNATURE", 0x1E: "LC_SEGMENT_SPLIT_INFO",
    0x21: "LC_ENCRYPTION_INFO", 0x22: "LC_DYLD_INFO",
    0x24: "LC_VERSION_MIN_MACOSX", 0x25: "LC_VERSION_MIN_IPHONEOS",
    0x26: "LC_FUNCTION_STARTS", 0x29: "LC_DATA_IN_CODE",
    0x2C: "LC_ENCRYPTION_INFO_64", 0x2D: "LC_LINKER_OPTION",
    0x2E: "LC_LINKER_OPTIMIZATION_HINT", 0x2F: "LC_VERSION_MIN_TVOS",
    0x30: "LC_VERSION_MIN_WATCHOS", 0x32: "LC_BUILD_VERSION",
    0x80000018: "LC_LOAD_WEAK_DYLIB", 0x8000001C: "LC_RPATH",
    0x8000001F: "LC_REEXPORT_DYLIB", 0x80000022: "LC_DYLD_INFO_ONLY",
    0x80000023: "LC_LOAD_UPWARD_DYLIB", 0x80000028: "LC_MAIN",
    0x80000033: "LC_DYLD_EXPORTS_TRIE", 0x80000034: "LC_DYLD_CHAINED_FIXUPS",
}
DYLIB_COMMANDS = {0xC, 0xD, 0x80000018, 0x8000001F, 0x80000023}
MACHO_MAGICS = {
    b"\xcf\xfa\xed\xfe": ("<", True),
    b"\xfe\xed\xfa\xcf": (">", True),
    b"\xce\xfa\xed\xfe": ("<", False),
    b"\xfe\xed\xfa\xce": (">", False),
}
FAT_MAGICS = {
    b"\xca\xfe\xba\xbe": (">", False),
    b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True),
    b"\xbf\xba\xfe\xca": ("<", True),
}


def require_span(data: bytes, offset: int, length: int, label: str) -> None:
    if offset < 0 or length < 0 or offset + length > len(data):
        raise InspectionError(f"{label}: out-of-bounds byte range {offset}+{length}")


def c_string(data: bytes, offset: int, limit: int, label: str) -> str:
    if not 0 <= offset < limit <= len(data):
        raise InspectionError(f"{label}: invalid string range")
    end = data.find(b"\0", offset, limit)
    if end < 0:
        raise InspectionError(f"{label}: unterminated string")
    return data[offset:end].decode("utf-8", errors="replace")


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_inventory(archive: zipfile.ZipFile, include_entries: bool) -> dict:
    entries = archive.infolist()
    names = [entry.filename for entry in entries]
    duplicates = [name for name, count in Counter(names).items() if count > 1]
    if duplicates:
        raise InspectionError(f"Ambiguous ZIP: duplicate entry names: {duplicates[:5]}")
    files = [entry for entry in entries if not entry.is_dir()]
    sources = []
    markers = []
    symbols = []
    for name in names:
        leaf = name.rstrip("/").rsplit("/", 1)[-1]
        suffix = Path(leaf).suffix.lower()
        if suffix in SOURCE_SUFFIXES and not name.endswith("/"):
            sources.append(name)
        if leaf.lower() in BUILD_MARKERS or any(
            part.lower().endswith((".xcodeproj", ".xcworkspace"))
            for part in name.rstrip("/").split("/")
        ):
            markers.append(name)
        if any(part.lower().endswith(".dsym") for part in name.split("/")):
            symbols.append(name)
    framework_headers = [name for name in sources if ".framework/Headers/" in name]
    result = {
        "entry_count": len(entries),
        "file_count": len(files),
        "directory_count": len(entries) - len(files),
        "uncompressed_bytes": sum(entry.file_size for entry in entries),
        "compressed_member_bytes": sum(entry.compress_size for entry in entries),
        "root_counts": dict(sorted(Counter(name.split("/", 1)[0] for name in names).items())),
        "file_suffix_counts": dict(sorted(Counter(
            Path(entry.filename).suffix.lower() or "[no suffix]" for entry in files
        ).items())),
        "source_candidates": sources,
        "framework_public_headers": framework_headers,
        "app_source_candidates": [name for name in sources if name not in framework_headers],
        "build_or_snapshot_markers": markers,
        "debug_symbol_entries": symbols,
        "largest_files": [
            {"path": entry.filename, "bytes": entry.file_size}
            for entry in sorted(files, key=lambda value: value.file_size, reverse=True)[:15]
        ],
    }
    if include_entries:
        result["entries"] = [
            {"path": entry.filename, "bytes": entry.file_size,
             "compressed_bytes": entry.compress_size, "crc32": f"{entry.CRC:08x}",
             "directory": entry.is_dir()}
            for entry in entries
        ]
    return result


def verify_crc(archive: zipfile.ZipFile, label: str) -> dict:
    bad = archive.testzip()
    if bad is not None:
        raise InspectionError(f"{label}: CRC verification failed for {bad}")
    return {"all_members_checked": True,
            "file_count": sum(not entry.is_dir() for entry in archive.infolist())}


def inspect_thin_macho(data: bytes, label: str) -> dict:
    magic = data[:4]
    if magic not in MACHO_MAGICS:
        raise InspectionError(f"{label}: invalid Mach-O magic")
    endian, is_64 = MACHO_MAGICS[magic]
    header_size = 32 if is_64 else 28
    require_span(data, 0, header_size, label)
    values = struct.unpack_from(endian + ("8I" if is_64 else "7I"), data)
    _, cpu, subtype, file_type, command_count, commands_size, flags = values[:7]
    require_span(data, header_size, commands_size, label)
    commands_end = header_size + commands_size
    offset = header_size
    commands = []
    encryption = []
    dylibs = []
    symbol_table = None
    for _ in range(command_count):
        require_span(data, offset, 8, label)
        command, size = struct.unpack_from(endian + "II", data, offset)
        if size < 8 or size % 4 or offset + size > commands_end:
            raise InspectionError(f"{label}: invalid load command at {offset}")
        entry = {"offset": offset, "command": f"0x{command:08x}",
                 "name": LOAD_COMMAND_NAMES.get(command, "UNKNOWN"), "bytes": size}
        if command in DYLIB_COMMANDS:
            if size < 24:
                raise InspectionError(f"{label}: truncated dylib command")
            name_offset, timestamp, current, compatibility = struct.unpack_from(
                endian + "4I", data, offset + 8
            )
            if name_offset < 24:
                raise InspectionError(f"{label}: invalid dylib name offset")
            name = c_string(data, offset + name_offset, offset + size, label)
            entry.update(path=name, timestamp=timestamp, current_version=current,
                         compatibility_version=compatibility)
            dylibs.append({"path": name, "load_command": entry["name"]})
        elif command in {0xE, 0xF, 0x8000001C}:
            if size < 12:
                raise InspectionError(f"{label}: truncated path command")
            name_offset = struct.unpack_from(endian + "I", data, offset + 8)[0]
            if name_offset < 12:
                raise InspectionError(f"{label}: invalid path offset")
            entry["path"] = c_string(data, offset + name_offset, offset + size, label)
        elif command in {0x21, 0x2C}:
            if size < (24 if command == 0x2C else 20):
                raise InspectionError(f"{label}: truncated encryption command")
            crypt_offset, crypt_size, crypt_id = struct.unpack_from(
                endian + "3I", data, offset + 8
            )
            require_span(data, crypt_offset, crypt_size, label)
            entry.update(cryptoff=crypt_offset, cryptsize=crypt_size, cryptid=crypt_id)
            encryption.append({"command": entry["name"], "cryptoff": crypt_offset,
                               "cryptsize": crypt_size, "cryptid": crypt_id})
        elif command == 0x2:
            if size < 24:
                raise InspectionError(f"{label}: truncated symbol-table command")
            symbol_table = struct.unpack_from(endian + "4I", data, offset + 8)
            entry.update(zip(("symoff", "nsyms", "stroff", "strsize"), symbol_table))
        elif command == 0x1B:
            if size < 24:
                raise InspectionError(f"{label}: truncated UUID command")
            entry["uuid_hex"] = data[offset + 8:offset + 24].hex()
        elif command in {0x1D, 0x26, 0x29, 0x80000033, 0x80000034}:
            if size < 16:
                raise InspectionError(f"{label}: truncated linkedit command")
            link_offset, link_size = struct.unpack_from(endian + "2I", data, offset + 8)
            require_span(data, link_offset, link_size, label)
            entry.update(dataoff=link_offset, datasize=link_size)
        elif command == 0x32:
            if size < 24:
                raise InspectionError(f"{label}: truncated build-version command")
            platform, minimum, sdk, tool_count = struct.unpack_from(endian + "4I", data, offset + 8)
            if 24 + tool_count * 8 > size:
                raise InspectionError(f"{label}: truncated build tools")
            entry.update(platform=platform, minos_packed=minimum, sdk_packed=sdk,
                         tool_count=tool_count)
        commands.append(entry)
        offset += size
    if offset != commands_end:
        raise InspectionError(f"{label}: load command count and sizeofcmds disagree")
    bootstrap_symbols = []
    if symbol_table:
        symbol_offset, symbol_count, string_offset, string_size = symbol_table
        record_size = 16 if is_64 else 12
        require_span(data, symbol_offset, symbol_count * record_size, label)
        require_span(data, string_offset, string_size, label)
        for index in range(symbol_count):
            name_index = struct.unpack_from(endian + "I", data, symbol_offset + index * record_size)[0]
            if name_index >= string_size:
                raise InspectionError(f"{label}: invalid symbol string index")
            if not name_index:
                continue
            name = c_string(data, string_offset + name_index, string_offset + string_size, label)
            if len(name) <= 250 and BOOTSTRAP_PATTERN.search(name):
                bootstrap_symbols.append(name)
    readable = [match.group().decode("ascii") for match in re.finditer(rb"[ -~]{5,250}", data)]
    bootstrap_strings = sorted(set(value for value in readable if BOOTSTRAP_PATTERN.search(value)))
    return {
        "bits": 64 if is_64 else 32, "byte_order": "little" if endian == "<" else "big",
        "cpu_type": f"0x{cpu:08x}", "cpu_subtype": subtype, "file_type": file_type,
        "flags": f"0x{flags:08x}", "load_command_count": command_count,
        "encryption_commands": encryption, "dylib_paths": dylibs,
        "bootstrap_symbols": sorted(set(bootstrap_symbols)),
        "bootstrap_runtime_string_evidence": bootstrap_strings,
        "load_commands": commands,
    }


def inspect_macho(data: bytes, label: str) -> dict:
    if data[:4] in MACHO_MAGICS:
        return {"container": "thin", "slices": [inspect_thin_macho(data, label)]}
    endian, fat_64 = FAT_MAGICS[data[:4]]
    require_span(data, 0, 8, label)
    count = struct.unpack_from(endian + "I", data, 4)[0]
    record_size = 32 if fat_64 else 20
    if not count or count > 64:
        raise InspectionError(f"{label}: invalid fat Mach-O slice count {count}")
    require_span(data, 8, count * record_size, label)
    slices = []
    ranges = []
    for index in range(count):
        values = struct.unpack_from(endian + ("IIQQII" if fat_64 else "5I"),
                                    data, 8 + index * record_size)
        cpu, subtype, offset, size, alignment = values[:5]
        if not size or offset < 8 + count * record_size:
            raise InspectionError(f"{label}: invalid fat Mach-O slice range")
        require_span(data, offset, size, label)
        if any(offset < end and offset + size > start for start, end in ranges):
            raise InspectionError(f"{label}: overlapping fat Mach-O slices")
        ranges.append((offset, offset + size))
        result = inspect_thin_macho(data[offset:offset + size], f"{label}[{index}]")
        if result["cpu_type"] != f"0x{cpu:08x}" or result["cpu_subtype"] != subtype:
            raise InspectionError(f"{label}: fat header and slice CPU disagree")
        result.update(container_offset=offset, container_bytes=size, alignment=alignment)
        slices.append(result)
    return {"container": "fat64" if fat_64 else "fat32", "slices": slices}


def inspect_class_constants(data: bytes, label: str) -> dict:
    require_span(data, 0, 10, label)
    if data[:4] != b"\xca\xfe\xba\xbe":
        raise InspectionError(f"{label}: invalid Java class magic")
    minor, major, count = struct.unpack_from(">3H", data, 4)
    if count < 1:
        raise InspectionError(f"{label}: invalid Java constant pool count")
    offset = 10
    index = 1
    constants = []
    while index < count:
        require_span(data, offset, 1, label)
        tag = data[offset]
        offset += 1
        if tag == 1:
            require_span(data, offset, 2, label)
            length = struct.unpack_from(">H", data, offset)[0]
            offset += 2
            require_span(data, offset, length, label)
            # Java's modified UTF-8 differs for nulls/surrogate pairs. Selected
            # evidence is ASCII; replacement avoids claiming metadata decoding.
            value = data[offset:offset + length].replace(b"\xc0\x80", b"\0").decode(
                "utf-8", errors="replace"
            )
            constants.append(value)
            offset += length
        else:
            widths = {3: 4, 4: 4, 5: 8, 6: 8, 7: 2, 8: 2, 9: 4, 10: 4,
                      11: 4, 12: 4, 15: 3, 16: 2, 17: 4, 18: 4, 19: 2, 20: 2}
            if tag not in widths:
                raise InspectionError(f"{label}: unsupported constant pool tag {tag}")
            require_span(data, offset, widths[tag], label)
            offset += widths[tag]
            if tag in {5, 6}:
                if index + 1 >= count:
                    raise InspectionError(f"{label}: invalid two-slot Java constant")
                index += 1
        index += 1
    evidence = sorted(set(value for value in constants if len(value) <= 250
                          and "\ufffd" not in value and ENGINE_CONSTANT_PATTERN.search(value)))
    return {"class_major_version": major, "class_minor_version": minor,
            "constant_pool_entries": count - 1, "utf8_constant_count": len(constants),
            "selected_utf8_constant_evidence": evidence}


def read_java_manifest(data: bytes) -> dict:
    text = data.decode("utf-8", errors="strict").replace("\r\n", "\n").replace("\r", "\n")
    unfolded = []
    for line in text.splitlines():
        if line.startswith(" ") and unfolded:
            unfolded[-1] += line[1:]
        else:
            unfolded.append(line)
    allowed = {"Manifest-Version", "Main-Class", "Implementation-Title",
               "Implementation-Vendor", "Specification-Version", "Implementation-Version"}
    result = {}
    for line in unfolded:
        if ": " in line:
            key, value = line.split(": ", 1)
            if key in allowed:
                result[key] = value
    return result


def inspect_backend(data: bytes, path: str, include_entries: bool) -> dict:
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        result = {"path": path, "sha256": hashlib.sha256(data).hexdigest(),
                  "inventory": inspect_inventory(archive, include_entries),
                  "crc_verification": verify_crc(archive, path)}
        names = set(archive.namelist())
        if "META-INF/MANIFEST.MF" in names:
            result["manifest"] = read_java_manifest(archive.read("META-INF/MANIFEST.MF"))
        if "server-reference.conf" in names:
            config = archive.read("server-reference.conf").decode("utf-8", errors="strict")
            result["default_server_config"] = {
                key: re.search(r"^" + re.escape(key) + r"\s*=\s*([^\r\n#]+)", config, re.MULTILINE).group(1).strip()
                for key in ("server.ip", "server.port", "server.webUIEnabled")
                if re.search(r"^" + re.escape(key) + r"\s*=", config, re.MULTILINE)
            }
        result["class_constant_evidence"] = {
            name: inspect_class_constants(archive.read(name), name)
            for name in ENGINE_CLASSES if name in names
        }
        result["bundled_extension_packages"] = sorted(
            name for name in names if name.lower().endswith((".apk", ".jar", ".dex"))
        )
        result["engine_package_class_counts"] = {
            prefix: sum(name.startswith(prefix) and name.endswith(".class") for name in names)
            for prefix in ("suwayomi/tachidesk/", "app/tachimanga/", "eu/kanade/tachiyomi/",
                           "mihon/", "xyz/nulldev/androidcompat/", "org/jsoup/", "okhttp3/",
                           "app/cash/quickjs/", "com/googlecode/d2j/", "com/googlecode/dex2jar/")
        }
        return result


def inspect_ipa(path: Path, include_entries: bool = False) -> dict:
    if not path.is_file():
        raise InspectionError(f"IPA file does not exist: {path}")
    digest = file_sha256(path)
    with zipfile.ZipFile(path) as archive:
        inventory = inspect_inventory(archive, include_entries)
        crc = verify_crc(archive, str(path))
        names = archive.namelist()
        app_info_paths = [name for name in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(app_info_paths) != 1:
            raise InspectionError(f"Expected one main app Info.plist, found {len(app_info_paths)}")
        info_path = app_info_paths[0]
        app_root = info_path.rsplit("/", 1)[0]
        info = plistlib.loads(archive.read(info_path))
        if not isinstance(info, dict):
            raise InspectionError("App Info.plist root must be a dictionary")
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or not executable or "/" in executable or "\\" in executable:
            raise InspectionError("Invalid or missing CFBundleExecutable")
        executable_path = app_root + "/" + executable
        if executable_path not in names:
            raise InspectionError("Main app executable is missing from IPA")
        result = {
            "format_version": 1,
            "inspection_scope": "Static read-only archive/plist/Mach-O/Java constant inspection; no contents executed or extracted",
            "input": {"path": str(path.resolve()), "bytes": path.stat().st_size, "sha256": digest},
            "outer_archive": {"inventory": inventory, "crc_verification": crc},
            "app": {"root": app_root, "info_plist_path": info_path,
                    "info_plist_fields": {key: info[key] for key in INFO_FIELDS if key in info},
                    "all_info_plist_key_names": sorted(info),
                    "info_plist_redaction": "Only listed app/build/document metadata values included; service config, entitlements and other plist values omitted"},
            "mach_o": [],
            "embedded_backend_archives": [],
            "limitations": [
                "cryptid=0 is static header evidence; it does not prove build, signing, installation or runtime compatibility",
                "Java bytecode and Dart source-path strings are not application source files",
                "Existing JS or JVM classes do not establish vBook or all manga extension host API compatibility",
                "Runtime string evidence is distinguished from named symbol-table entries",
            ],
        }
        for member in archive.infolist():
            if member.is_dir() or member.file_size < 4:
                continue
            with archive.open(member) as stream:
                magic = stream.read(4)
            if magic in MACHO_MAGICS or magic in FAT_MAGICS:
                data = archive.read(member)
                # Java .class magic matches FAT_MAGIC, but classes are not
                # expected as native Mach-O members in the outer app bundle.
                if member.filename.endswith(".class"):
                    continue
                parsed = inspect_macho(data, member.filename)
                parsed.update(path=member.filename, bytes=member.file_size,
                              sha256=hashlib.sha256(data).hexdigest())
                result["mach_o"].append(parsed)
                if member.filename.endswith("/App.framework/App"):
                    readable = [match.group().decode("ascii") for match in re.finditer(rb"[ -~]{5,500}", data)]
                    paths = sorted(set(value for value in readable if value.startswith("package:tachidesk_sorayomi/")))
                    result["flutter_aot_evidence"] = {
                        "path": member.filename, "source_path_string_count": len(paths),
                        "source_path_string_samples": paths[:20],
                        "local_backend_url_literal_present": b"http://127.0.0.1:4567" in data,
                        "dart_identifiers_present": [name for name in ("dart:core", "dart:ffi", "dart:io", "dart:async")
                                                     if name.encode("ascii") in data],
                    }
            if member.filename.endswith("/MCHome.bundle/res.zip"):
                result["embedded_backend_archives"].append(
                    inspect_backend(archive.read(member), member.filename, include_entries)
                )
        if not any(item["path"] == executable_path for item in result["mach_o"]):
            raise InspectionError("Main app executable is not a recognized Mach-O file")
        slices = [value for binary in result["mach_o"] for value in binary["slices"]]
        result["mach_o_summary"] = {
            "binary_count": len(result["mach_o"]), "slice_count": len(slices),
            "cpu_type_counts": dict(Counter(value["cpu_type"] for value in slices)),
            "encryption_command_count": sum(len(value["encryption_commands"]) for value in slices),
            "cryptid_counts": dict(Counter(str(command["cryptid"]) for value in slices
                                            for command in value["encryption_commands"])),
            "slices_without_encryption_commands": sum(not value["encryption_commands"] for value in slices),
        }
        result["framework_names"] = sorted(set(
            match.group(1) for name in names
            if (match := re.search(r"/Frameworks/([^/]+\.framework)/", name))
        ))
        result["dylib_members"] = sorted(name for name in names if name.endswith(".dylib"))
        result["flutter_asset_file_count"] = sum(
            "/flutter_assets/" in name and not name.endswith("/") for name in names
        )
    # Prevent a changing source from silently producing evidence with an old hash.
    if file_sha256(path) != digest:
        raise InspectionError("IPA changed while it was being inspected; no report written")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path, help="Path to the original IPA")
    parser.add_argument("--output", type=Path, required=True, help="Write inspection JSON to this path")
    parser.add_argument("--include-inventory", action="store_true", help="Include all outer/nested member paths, CRCs and sizes")
    args = parser.parse_args()
    input_path = args.ipa.resolve()
    output_path = args.output.resolve()
    if input_path == output_path:
        parser.error("--output must not overwrite the input IPA")
    temporary = output_path.with_name(output_path.name + ".tmp")
    if input_path == temporary:
        parser.error("--output temporary path must not overwrite the input IPA")
    try:
        report = inspect_ipa(input_path, args.include_inventory)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with temporary.open("w", encoding="utf-8", newline="\n") as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        temporary.replace(output_path)
    except (InspectionError, OSError, ValueError, TypeError, UnicodeError, struct.error,
            zipfile.BadZipFile, RuntimeError, EOFError) as exc:
        print(f"Inspection failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps({"output": str(output_path), "ipa_sha256": report["input"]["sha256"],
                      "outer_entries": report["outer_archive"]["inventory"]["entry_count"],
                      "mach_o": report["mach_o_summary"],
                      "nested_crc_checked": len(report["embedded_backend_archives"])}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
