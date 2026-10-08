"""Inspect local vBook ZIP packages or JSON manifests/registries without execution.

This is a structural inspector, not a vBook runtime. JavaScript API and load()
scans are heuristics: comments and strings can match, and dynamic calls can be
missed. No network requests, decryption, extraction or script execution occur.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any


@dataclass(frozen=True)
class Limits:
    max_input_bytes: int = 64 * 1024 * 1024
    max_entries: int = 512
    max_entry_bytes: int = 10 * 1024 * 1024
    max_uncompressed_bytes: int = 64 * 1024 * 1024
    max_manifest_bytes: int = 2 * 1024 * 1024
    max_registry_items: int = 10000


class InspectionError(ValueError):
    """Input cannot be inspected safely or parsed as the expected format."""


CORE_SCRIPTS = {
    "novel": ("detail", "toc", "chap"),
    "comic": ("detail", "toc", "chap"),
    "audio": ("detail", "toc", "chap", "track"),
    "video": ("detail", "toc", "chap", "track"),
    "tts": ("voice", "tts"),
    "translate": ("language", "translate"),
    "ai": ("chatStream",),
}
BUILTIN_LOADS = {"crypto.js"}
HOST_APIS = (
    "fetch", "Http", "Response", "Html", "Engine", "UserAgent", "Console",
    "Log", "console", "sleep", "load", "localStorage", "cacheStorage",
    "localConfig", "localCookie", "localDatabase", "localBook", "Script",
    "CryptoJS", "Graphics", "WebSocket", "QT", "Blob",
)
LOAD_PATTERN = re.compile(r"\bload\s*\(\s*(['\"])([^'\"\r\n]+)\1\s*\)")
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z_$][A-Za-z0-9_$]*$")


def _finding(result: dict[str, Any], severity: str, code: str, message: str,
             **details: Any) -> None:
    result["findings"].append({"severity": severity, "code": code,
                                "message": message, **details})


def _safe_name(name: str) -> str:
    if not name or "\x00" in name or "\\" in name:
        raise InspectionError(f"Unsafe archive or script path: {name!r}")
    path = PurePosixPath(name)
    if path.is_absolute() or ":" in name or any(part in (".", "..", "")
                                               for part in name.rstrip("/").split("/")):
        raise InspectionError(f"Unsafe archive or script path: {name!r}")
    return str(path)


def _decode_json(data: bytes, label: str) -> Any:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise InspectionError(f"Duplicate JSON key in {label}: {key!r}")
            value[key] = item
        return value

    try:
        return json.loads(data.decode("utf-8-sig"),
                          object_pairs_hook=reject_duplicate_keys,
                          parse_constant=lambda value: (_ for _ in ()).throw(
                              InspectionError(f"Non-finite JSON value in {label}: {value}")))
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise InspectionError(f"Invalid JSON in {label}: {error}") from error


def _manifest(manifest: Any, result: dict[str, Any],
              scripts: dict[str, bytes] | None) -> None:
    if not isinstance(manifest, dict):
        raise InspectionError("Package manifest must be a JSON object.")
    metadata = manifest.get("metadata", {})
    if not isinstance(metadata, dict):
        raise InspectionError("Manifest metadata must be a JSON object.")
    mapping = manifest.get("script", {})
    if not isinstance(mapping, dict):
        raise InspectionError("Manifest script must be a JSON object.")
    config = manifest.get("config", {})
    if not isinstance(config, dict):
        raise InspectionError("Manifest config must be a JSON object.")

    raw_type = metadata.get("type", "novel")
    if not isinstance(raw_type, str):
        raise InspectionError("Manifest metadata.type must be a string.")
    normalized_type = raw_type.lower()
    if normalized_type == "chinese_novel":
        normalized_type = "novel"
        _finding(result, "warning", "legacy_type",
                 "chinese_novel is a legacy text-source type; inspected as novel.")
    if normalized_type not in CORE_SCRIPTS:
        _finding(result, "warning", "unknown_type",
                 "Unknown extension type; no required-script baseline is assumed.",
                 type=raw_type)
    encryption = metadata.get("encrypt", False)
    if not isinstance(encryption, bool):
        _finding(result, "error", "invalid_encrypt_flag",
                 "metadata.encrypt must be a JSON boolean.")
    encrypted = encryption is True
    result["manifest"] = {"metadata": metadata, "script": mapping, "config": config,
                          "actions": manifest.get("actions", {})}
    result["content_type"] = {"declared": raw_type, "normalized": normalized_type}
    result["encryption"] = {"declared": encrypted, "decryption_attempted": False,
                             "script_scan_skipped": encrypted}
    result["required_script_baseline"] = {
        "profile": "legacy_reading_core_with_documented_engine_types",
        "keys": list(CORE_SCRIPTS.get(normalized_type, ())),
        "note": "Legacy docs make search optional; newer docs require it for content types. "
                "This baseline does not establish runtime compatibility.",
    }
    for key in CORE_SCRIPTS.get(normalized_type, ()):
        if not mapping.get(key):
            _finding(result, "error", "missing_required_script",
                     f"Required script mapping is missing: {key}.", script_key=key)
    if normalized_type in {"novel", "comic", "audio", "video"} and not mapping.get("search"):
        _finding(result, "warning", "missing_modern_search",
                 "No search script: allowed by legacy docs, required by newer content-source docs.")

    for key, value in mapping.items():
        if not isinstance(value, str) or not value:
            _finding(result, "error", "invalid_script_filename",
                     "Declared script filename must be a nonempty string.", script_key=key)
            continue
        _safe_name(value)
        if "/" in value or not value.endswith(".js"):
            _finding(result, "error", "invalid_script_filename",
                     "Declared scripts must be .js files at the top level of src/.",
                     script_key=key, filename=value)
        if scripts is not None and value not in scripts:
            _finding(result, "error", "missing_declared_script_file",
                     "Declared script file is absent from src/.", script_key=key, filename=value)
    for key, value in config.items():
        if not IDENTIFIER_PATTERN.fullmatch(key):
            _finding(result, "warning", "invalid_config_identifier",
                     "Static config key cannot be injected as a JavaScript identifier.", key=key)
        if not isinstance(value, dict) and key not in {"thread_num", "delay", "ignore"}:
            _finding(result, "warning", "unrecognized_config_shape",
                     "Config item is not an object or a documented bare connection key.", key=key)
    if encrypted:
        _finding(result, "warning", "encrypted_scripts_uninspected",
                 "Package declares encrypted scripts. No decryption or JS scan was attempted.")
    result["script_scan"] = {
        "method": "heuristic_text_scan",
        "limitations": "Comments/strings may match; dynamic calls may be missed. "
                       "Findings do not prove APIs are implemented or scripts execute correctly.",
        "files": [],
    }
    if scripts is None:
        result["script_files_verified"] = False
        _finding(result, "warning", "manifest_only",
                 "Standalone manifest: script contents and file existence were not checked.")
        return
    result["script_files_verified"] = True
    for filename, data in sorted(scripts.items()):
        scan: dict[str, Any] = {"filename": filename, "size_bytes": len(data),
                                "sha256": hashlib.sha256(data).hexdigest()}
        if encrypted:
            scan["scan_status"] = "skipped_encrypted"
        else:
            try:
                source = data.decode("utf-8-sig")
            except UnicodeError:
                scan["scan_status"] = "skipped_non_utf8"
                _finding(result, "warning", "script_non_utf8",
                         "Script is not UTF-8; textual scan skipped.", filename=filename)
            else:
                scan["scan_status"] = "scanned_without_execution"
                scan["host_api_names"] = [name for name in HOST_APIS if re.search(
                    rf"(?<![\w$]){re.escape(name)}\s*(?:\.|\()", source)]
                scan["contains_execute_declaration"] = bool(re.search(
                    r"\bfunction\s+execute\s*\(", source))
                dependencies = []
                for _, dependency in LOAD_PATTERN.findall(source):
                    try:
                        _safe_name(dependency)
                    except InspectionError:
                        status = "unsafe_path"
                    else:
                        status = ("package_file" if dependency in scripts else
                                  "documented_builtin" if dependency in BUILTIN_LOADS else "missing")
                    dependencies.append({"filename": dependency, "status": status})
                    if status in {"missing", "unsafe_path"}:
                        _finding(result, "warning", "heuristic_load_dependency",
                                 "Literal load() target was not resolved within this package/builtin list.",
                                 filename=filename, dependency=dependency, resolution=status)
                scan["literal_load_dependencies"] = dependencies
        result["script_scan"]["files"].append(scan)


def _registry(value: Any, result: dict[str, Any], limits: Limits) -> None:
    if isinstance(value, list):
        items, metadata = value, {}
    elif isinstance(value, dict) and isinstance(value.get("data"), list):
        items, metadata = value["data"], value.get("metadata", {})
    else:
        raise InspectionError("Registry must be an array or an object containing a data array.")
    if len(items) > limits.max_registry_items:
        raise InspectionError("Registry exceeds item-count limit.")
    result["kind"] = "registry"
    result["registry"] = {"metadata": metadata, "item_count": len(items), "entries": []}
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            _finding(result, "error", "invalid_registry_entry", "Registry entry must be an object.",
                     index=index)
            continue
        entry = {key: item[key] for key in ("name", "author", "path", "version", "source",
                                           "icon", "type", "locale") if key in item}
        entry["index"] = index
        entry["package_downloaded"] = False
        result["registry"]["entries"].append(entry)
        if not isinstance(item.get("path"), str) or not item.get("path"):
            _finding(result, "error", "missing_registry_package_path",
                     "Registry entry has no string package path.", index=index)
    _finding(result, "info", "registry_only",
             "Registry entries were read locally. No package was downloaded or verified.")


def _package(path: Path, result: dict[str, Any], limits: Limits) -> None:
    result["kind"] = "package"
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if len(entries) > limits.max_entries:
                raise InspectionError("ZIP exceeds entry-count limit.")
            seen: set[str] = set()
            total = 0
            for entry in entries:
                # ZipInfo normalizes OS separators and truncates NULs; validate
                # the original central-directory name before accepting that form.
                normalized = _safe_name(entry.orig_filename)
                collision_key = normalized.casefold()
                if collision_key in seen:
                    raise InspectionError(f"Duplicate/case-colliding ZIP path: {entry.filename!r}")
                seen.add(collision_key)
                if stat.S_ISLNK(entry.external_attr >> 16):
                    raise InspectionError(f"ZIP symlink is not supported: {entry.filename!r}")
                if entry.flag_bits & 1:
                    raise InspectionError("ZIP-level encryption is unsupported; no password/decryption attempted.")
                if entry.file_size > limits.max_entry_bytes:
                    raise InspectionError(f"ZIP entry exceeds size limit: {entry.filename!r}")
                total += entry.file_size
                if total > limits.max_uncompressed_bytes:
                    raise InspectionError("ZIP exceeds total uncompressed-size limit.")
            result["archive"] = {"entry_count": len(entries), "uncompressed_bytes": total,
                                  "paths_validated": True, "files_extracted": False}
            try:
                manifest_entry = archive.getinfo("plugin.json")
            except KeyError as error:
                raise InspectionError("ZIP has no root plugin.json manifest.") from error
            if manifest_entry.file_size > limits.max_manifest_bytes:
                raise InspectionError("Manifest exceeds size limit.")
            manifest = _decode_json(archive.read(manifest_entry), "plugin.json")
            scripts = {entry.filename[4:]: archive.read(entry) for entry in entries
                       if not entry.is_dir() and entry.filename.startswith("src/")
                       and entry.filename.count("/") == 1 and entry.filename.endswith(".js")}
            if not scripts:
                _finding(result, "error", "no_readable_scripts", "ZIP has no top-level src/*.js files.")
            _manifest(manifest, result, scripts)
    except (zipfile.BadZipFile, RuntimeError, NotImplementedError, OSError) as error:
        raise InspectionError(f"Cannot read ZIP package: {error}") from error


def inspect_file(path: str | Path, limits: Limits | None = None) -> dict[str, Any]:
    limits = limits or Limits()
    input_path = Path(path).resolve()
    result: dict[str, Any] = {"schema_version": 1, "input": str(input_path),
                              "inspection_only": True, "runtime_compatibility": "not_tested",
                              "findings": [], "limits": vars(limits)}
    try:
        size = input_path.stat().st_size
        result["size_bytes"] = size
        if size > limits.max_input_bytes:
            raise InspectionError("Input exceeds file-size limit.")
        digest = hashlib.sha256()
        with input_path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
        result["sha256"] = digest.hexdigest()
        if zipfile.is_zipfile(input_path):
            _package(input_path, result, limits)
        else:
            value = _decode_json(input_path.read_bytes(), input_path.name)
            if isinstance(value, dict) and "script" in value:
                if size > limits.max_manifest_bytes:
                    raise InspectionError("Manifest exceeds size limit.")
                result["kind"] = "manifest"
                _manifest(value, result, None)
            else:
                _registry(value, result, limits)
    except (InspectionError, OSError) as error:
        _finding(result, "error", "inspection_rejected", str(error))
    result["status"] = ("invalid" if any(item["severity"] == "error" for item in result["findings"])
                        else "inspected")
    return result


def _positive_int(value: str) -> int:
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("Limit must be a positive integer.")
    return number


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Local vBook ZIP or JSON manifest/registry")
    parser.add_argument("--output", type=Path, help="Write JSON report to this path; otherwise stdout")
    for field, default in vars(Limits()).items():
        parser.add_argument("--" + field.replace("_", "-"), type=_positive_int, default=default)
    args = parser.parse_args(argv)
    if args.output and args.input.resolve() == args.output.resolve():
        parser.error("Output must not overwrite the input package or JSON.")
    limits = Limits(**{field: getattr(args, field) for field in vars(Limits())})
    result = inspect_file(args.input, limits)
    payload = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload, encoding="utf-8")
    else:
        sys.stdout.buffer.write(payload.encode("utf-8"))
    return 1 if result["status"] == "invalid" else 0


if __name__ == "__main__":
    raise SystemExit(main())
