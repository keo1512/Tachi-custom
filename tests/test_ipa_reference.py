"""Synthetic fixtures exercise audit invariants without redistributing the IPA."""

from __future__ import annotations

from dataclasses import replace
import hashlib
import io
import json
from pathlib import Path
import plistlib
import stat
import struct
import sys
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import ipa_reference as audit


ROOT = "Payload/Tachimanga.app"
ASSET = b"INDEPENDENT-ASSET-CONTENT-12345"


def command(kind: int, payload: bytes) -> bytes:
    length = (8 + len(payload) + 7) // 8 * 8
    return struct.pack("<2I", kind, length) + payload + b"\0" * (length - 8 - len(payload))


def macho(file_type: int = 2, *, cpu: int = 0x0100000C, commands: list[bytes] | None = None) -> bytes:
    if commands is None:
        commands = [command(0xC, struct.pack("<4I", 24, 0, 0, 0) + b"@rpath/Flutter.framework/Flutter\0"),
                    command(0x8000001C, struct.pack("<I", 12) + b"@executable_path/Frameworks\0"),
                    command(0x2C, struct.pack("<4I", 0, 0, 0, 0))]
    region = b"".join(commands)
    return struct.pack("<8I", 0xFEEDFACF, cpu, 0, file_type, len(commands), len(region), 0, 0) + region


def fat_macho(*, overlap: bool = False, mismatch: bool = False) -> bytes:
    first, second = macho(), macho(cpu=0x01000007)
    first_start, second_start = 64, 256
    if overlap:
        second_start = first_start
    table = struct.pack(">2I", 0xCAFEBABE, 2)
    table += struct.pack(">5I", 0x0100000C, 0, first_start, len(first), 0)
    table += struct.pack(">5I", 0x01000007, 0, second_start, len(second), 0)
    result = bytearray(max(second_start + len(second), first_start + len(first)))
    result[:len(table)] = table
    result[first_start:first_start + len(first)] = first
    result[second_start:second_start + len(second)] = first if mismatch else second
    return bytes(result)


def class_file(major: int = 52) -> bytes:
    # Header is the audit's deliberate class-validation boundary.
    return struct.pack(">I3H", 0xCAFEBABE, 0, major, 1) + b"\0" * 14


def zip_bytes(items: list[tuple[str | zipfile.ZipInfo, bytes]], compression=zipfile.ZIP_STORED) -> bytes:
    buffer = io.BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(buffer, "w", compression=compression) as archive:
            for name, data in items:
                if isinstance(name, str):
                    # ZipInfo normalizes backslashes on Windows; deliberately
                    # preserve raw ZIP names to exercise malicious fixtures.
                    info = zipfile.ZipInfo()
                    info.filename = info.orig_filename = name
                    info.compress_type = compression
                    name = info
                archive.writestr(name, data)
    return buffer.getvalue()


def backend_bytes(*, extras=(), manifest: bytes | None = None) -> bytes:
    if manifest is None:
        manifest = (b"Manifest-Version: 1.0\r\nMain-Class: suwayomi.tachidesk.\r\n"
                    b" MainKt\r\nImplementation-Title: Tachidesk-Server\r\n\r\n")
    return zip_bytes([("META-INF/MANIFEST.MF", manifest),
                      ("suwayomi/tachidesk/MainKt.class", class_file()),
                      ("eu/kanade/tachiyomi/Source.class", class_file(55)),
                      ("app/tachimanga/Bridge.class", class_file()), *extras])


def ipa_bytes(*, extras=(), plist: bytes | None = None, backend: bytes | None = None,
              main: bytes | None = None, flutter: bytes | None = None, compression=zipfile.ZIP_STORED) -> bytes:
    if plist is None:
        plist = plistlib.dumps({"CFBundleIdentifier": "com.mangacrush.ios", "CFBundleExecutable": "Tachimanga",
                               "CFBundleShortVersionString": "5.0", "CFBundleVersion": "511", "MinimumOSVersion": "15.0"},
                              fmt=plistlib.FMT_BINARY)
    return zip_bytes([(ROOT + "/Info.plist", plist),
                      (ROOT + "/Tachimanga", macho() if main is None else main),
                      (ROOT + "/Frameworks/App.framework/App", macho(6) if flutter is None else flutter),
                      (ROOT + "/MCHome.bundle/res.zip", backend_bytes() if backend is None else backend),
                      (ROOT + "/assets/reference.txt", ASSET), *extras], compression)


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "original.ipa"
        self.output = self.directory / "evidence.json"

    def tearDown(self):
        self.temporary.cleanup()

    def run_audit(self, data: bytes | None = None, **kwargs):
        self.source.write_bytes(ipa_bytes() if data is None else data)
        return audit.audit_ipa(self.source, **kwargs)

    def assert_rejected(self, data: bytes, message: str | None = None, **kwargs):
        self.source.write_bytes(data)
        original = self.source.read_bytes()
        with self.assertRaises(audit.AuditError, msg=message):
            audit.write_evidence(self.source, self.output, **kwargs)
        self.assertEqual(original, self.source.read_bytes())
        self.assertFalse(self.output.exists())
        self.assertEqual([], list(self.directory.glob(".ipa-reference-*.tmp")))

    def test_inventory_hashes_metadata_and_static_boundary(self):
        data = ipa_bytes()
        evidence = self.run_audit(data)
        self.assertEqual(hashlib.sha256(data).hexdigest(), evidence["source"]["sha256_before"])
        self.assertEqual(evidence["source"]["sha256_before"], evidence["source"]["sha256_after"])
        self.assertTrue(evidence["source"]["unchanged_during_audit"])
        self.assertEqual("5.0", evidence["app"]["version"])
        self.assertEqual("511", evidence["app"]["build"])
        self.assertEqual("15.0", evidence["app"]["minimum_ios"])
        self.assertEqual(5, evidence["ipa"]["file_count"])
        self.assertTrue(evidence["ipa"]["crc_checked_for_all_entries"])
        self.assertFalse(evidence["runtime"]["verified"])
        asset = next(item for item in evidence["ipa"]["inventory"] if item["path"].endswith("reference.txt"))
        self.assertEqual(hashlib.sha256(ASSET).hexdigest(), asset["sha256"])
        self.assertEqual(3, evidence["backend"]["class_count"])
        self.assertEqual(1, evidence["backend"]["class_namespace_counts"]["suwayomi/"])
        self.assertEqual({"52.0": 2, "55.0": 1}, evidence["backend"]["class_version_counts"])
        self.assertEqual("suwayomi.tachidesk.MainKt", evidence["backend"]["manifests"][0]["main_attributes"]["Main-Class"])
        self.assertEqual(hashlib.sha256(class_file()).hexdigest(), evidence["backend"]["representative_class_sha256"]["suwayomi/tachidesk/MainKt.class"])
        self.assertIn("org/tachiyomi/NativeChannel.class", evidence["backend"]["representative_classes_missing"])
        main = evidence["binaries"]["main"]
        self.assertEqual(["arm64"], main["architectures"])
        self.assertFalse(main["encrypted"])
        self.assertEqual("@executable_path/Frameworks", main["slices"][0]["rpaths"][0])
        self.assertEqual("@rpath/Flutter.framework/Flutter", main["slices"][0]["dylib_paths"][0]["path"])

    def test_deflated_archive_and_private_disk_spool(self):
        evidence = self.run_audit(ipa_bytes(compression=zipfile.ZIP_DEFLATED), limits=replace(audit.Limits(), spool_memory_bytes=1))
        self.assertEqual(3, evidence["backend"]["class_count"])
        self.assertEqual(["original.ipa"], [path.name for path in self.directory.iterdir()])

    def test_directory_entries_are_in_inventory(self):
        evidence = self.run_audit(ipa_bytes(extras=[("Payload/", b"")]))
        self.assertEqual(1, evidence["ipa"]["directory_count"])
        self.assertIsNone(evidence["ipa"]["inventory"][-1]["sha256"])

    def test_explicit_strict_reference_rejects_other_ipa(self):
        self.assert_rejected(ipa_bytes(), strict_reference=True)

    def test_strict_reference_checks_identity_and_metadata(self):
        data = ipa_bytes()
        with mock.patch.object(audit, "REFERENCE_SHA256", hashlib.sha256(data).hexdigest()):
            self.assertTrue(self.run_audit(data, strict_reference=True)["source"]["matches_pinned_reference"])
        plist = plistlib.dumps({"CFBundleIdentifier": "com.mangacrush.ios", "CFBundleExecutable": "Tachimanga",
                               "CFBundleShortVersionString": "5.1", "CFBundleVersion": "511", "MinimumOSVersion": "15.0"})
        data = ipa_bytes(plist=plist)
        with mock.patch.object(audit, "REFERENCE_SHA256", hashlib.sha256(data).hexdigest()):
            self.assert_rejected(data, strict_reference=True)

    def test_unsafe_paths_are_rejected_before_streaming(self):
        for name in ("../escape", "/absolute", "C:/drive", "Payload\\escape", "a/../b", "a/./b", "a//b", "a:/b", "a./b", "a /b", "a/\x01b"):
            with self.subTest(name=name):
                self.assert_rejected(ipa_bytes(extras=[(name, b"x")]))

    def test_duplicate_and_portable_name_collisions(self):
        for items in ([('duplicate', b'1'), ('duplicate', b'2')],
                      [('Case', b'1'), ('case', b'2')],
                      [('caf\u00e9', b'1'), ('cafe\u0301', b'2')],
                      [('directory', b'1'), ('directory/', b'')],
                      [('ancestor', b'1'), ('ancestor/child', b'2')]):
            with self.subTest(items=items):
                self.assert_rejected(ipa_bytes(extras=items))

    def test_symlink_and_special_file_entries_are_rejected(self):
        for mode in (stat.S_IFLNK | 0o777, stat.S_IFIFO | 0o600):
            info = zipfile.ZipInfo("unsafe")
            info.create_system = 3
            info.external_attr = mode << 16
            self.assert_rejected(ipa_bytes(extras=[(info, b"target")]))

    def test_directory_with_data_is_rejected(self):
        self.assert_rejected(ipa_bytes(extras=[("directory/", b"hidden payload")]))

    def test_nested_archive_uses_same_safety_rules(self):
        for extras in ([('.. /bad', b'x')], [('unsafe\\name', b'x')],
                       [('duplicate', b'1'), ('duplicate', b'2')]):
            with self.subTest(extras=extras):
                self.assert_rejected(ipa_bytes(backend=backend_bytes(extras=extras)))

    def test_main_plist_missing_or_ambiguous_is_rejected(self):
        self.assert_rejected(zip_bytes([("file", b"data")]))
        self.assert_rejected(ipa_bytes(extras=[("Payload/Other.app/Info.plist", plistlib.dumps({}))]))

    def test_malformed_and_non_dictionary_plists_are_rejected(self):
        for plist in (b"not a plist", b"<?xml version='1.0'?><plist><dict>", plistlib.dumps(["unexpected"])):
            with self.subTest(plist=plist):
                self.assert_rejected(ipa_bytes(plist=plist))

    def test_required_metadata_and_executable_path_are_validated(self):
        fields = {"CFBundleIdentifier": "com.test.app", "CFBundleExecutable": "Tachimanga",
                  "CFBundleShortVersionString": "5.0", "CFBundleVersion": "511", "MinimumOSVersion": "15.0"}
        for key, value in (("CFBundleVersion", None), ("CFBundleVersion", 511),
                           ("CFBundleExecutable", "../outside"), ("MinimumOSVersion", "tomorrow"),
                           ("CFBundleIdentifier", "broken identifier")):
            with self.subTest(key=key, value=value):
                modified = {**fields, key: value}
                if value is None:
                    del modified[key]
                self.assert_rejected(ipa_bytes(plist=plistlib.dumps(modified)))

    def test_missing_required_binaries_and_nested_zip_are_rejected(self):
        original = zipfile.ZipFile(io.BytesIO(ipa_bytes()))
        for omitted in (ROOT + "/Tachimanga", ROOT + "/Frameworks/App.framework/App", ROOT + "/MCHome.bundle/res.zip"):
            with self.subTest(omitted=omitted):
                self.assert_rejected(zip_bytes([(info.filename, original.read(info)) for info in original.infolist() if info.filename != omitted]))
        original.close()

    def test_malformed_macho_headers_commands_and_types(self):
        bad_length = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 8, 0, 0) + struct.pack("<2I", 0xC, 0)
        bad_count = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 8, 0, 0) + b"\0" * 8
        for main in (b"not MachO", b"\xcf\xfa\xed\xfe", macho()[:-1], bad_length, bad_count, macho(6)):
            with self.subTest(main=main[:12]):
                self.assert_rejected(ipa_bytes(main=main))

    def test_macho_string_offsets_and_termination(self):
        for payload in (struct.pack("<4I", 8, 0, 0, 0) + b"path\0", struct.pack("<4I", 24, 0, 0, 0) + b"x" * 8):
            self.assert_rejected(ipa_bytes(main=macho(commands=[command(0xC, payload)])))

    def test_macho_encryption_flag_is_recorded_without_runtime_claim(self):
        encrypted = macho(commands=[command(0x2C, struct.pack("<4I", 0, 0, 1, 0))])
        evidence = self.run_audit(ipa_bytes(main=encrypted))
        self.assertTrue(evidence["binaries"]["main"]["encrypted"])
        self.assertFalse(evidence["runtime"]["verified"])
        self.assert_rejected(ipa_bytes(main=macho(commands=[command(0x2C, struct.pack("<4I", 500, 20, 0, 0))])))

    def test_macho_segments_and_signature_ranges_are_bounded(self):
        segment = struct.pack("<16s4Q4I", b"__TEXT", 0, 4096, 0, 500, 0, 0, 0, 0)
        self.assert_rejected(ipa_bytes(main=macho(commands=[command(0x19, segment)])))
        self.assert_rejected(ipa_bytes(main=macho(commands=[command(0x1D, struct.pack("<2I", 500, 20))])))

    def test_fat_macho_architectures_and_invalid_slices(self):
        parsed = audit.parse_macho(io.BytesIO(fat_macho()), len(fat_macho()), audit.Limits())
        self.assertEqual(["arm64", "x86_64"], parsed["architectures"])
        for data in (fat_macho(overlap=True), fat_macho(mismatch=True), fat_macho()[:-1]):
            with self.subTest(size=len(data)):
                with self.assertRaises(audit.AuditError):
                    audit.parse_macho(io.BytesIO(data), len(data), audit.Limits())

    def test_invalid_class_headers_are_rejected(self):
        for data in (b"class", b"INVALID!!!", class_file(1), struct.pack(">I3H", 0xCAFEBABE, 0, 52, 0)):
            with self.subTest(data=data):
                self.assert_rejected(ipa_bytes(backend=backend_bytes(extras=[("Broken.class", data)])))

    def test_invalid_nested_zip_and_manifest_are_rejected(self):
        self.assert_rejected(ipa_bytes(backend=b"not zip"))
        for manifest in (b"bad attribute", b" continued without key", b"A: 1\na: 2\n", b"A: \xff", b"A: \0"):
            with self.subTest(manifest=manifest):
                self.assert_rejected(ipa_bytes(backend=backend_bytes(manifest=manifest)))

    def test_crc_corruption_and_wrong_local_header_name_are_rejected(self):
        original = ipa_bytes()
        corrupted = bytearray(original)
        index = corrupted.index(ASSET)
        corrupted[index] ^= 1
        self.assert_rejected(bytes(corrupted))
        corrupted = bytearray(original)
        name = (ROOT + "/assets/reference.txt").encode()
        index = corrupted.index(name)
        corrupted[index + len(name) - 1] ^= 1
        self.assert_rejected(bytes(corrupted))

    def test_nested_crc_corruption_is_rejected(self):
        nested = bytearray(backend_bytes())
        index = nested.index(b"Tachidesk-Server")
        nested[index] ^= 1
        self.assert_rejected(ipa_bytes(backend=bytes(nested)))

    def test_trailing_data_and_malformed_end_record_are_rejected(self):
        self.assert_rejected(ipa_bytes() + b"trailing")
        self.assert_rejected(ipa_bytes()[:-1])
        corrupted = bytearray(ipa_bytes())
        struct.pack_into("<I", corrupted, len(corrupted) - 6, 0xFFFFFFFF)
        self.assert_rejected(bytes(corrupted))

    def test_resource_limits_cover_metadata_and_streamed_resources(self):
        for overrides in ({"max_entries": 2}, {"max_entry_bytes": 10}, {"max_total_bytes": 20},
                          {"max_central_directory_bytes": 20}, {"max_plist_bytes": 20},
                          {"max_load_command_bytes": 8}, {"max_manifest_bytes": 10}):
            with self.subTest(overrides=overrides):
                self.assert_rejected(ipa_bytes(), limits=replace(audit.Limits(), **overrides))
        self.assert_rejected(ipa_bytes(extras=[("bomb", b"z" * 100_000)], compression=zipfile.ZIP_DEFLATED),
                             limits=replace(audit.Limits(), max_compression_ratio=10))
        with self.assertRaises(audit.AuditError):
            audit.Limits(max_entries=0)

    def test_nested_limits_are_applied_independently(self):
        nested = backend_bytes(extras=[("asset" + str(index), b"x") for index in range(10)])
        self.assert_rejected(ipa_bytes(backend=nested), limits=replace(audit.Limits(), max_entries=10))

    def test_no_partial_output_on_failed_validation(self):
        self.assert_rejected(b"not zip")

    def test_atomic_evidence_and_source_preservation(self):
        original = ipa_bytes()
        self.source.write_bytes(original)
        evidence = audit.write_evidence(self.source, self.output)
        self.assertEqual(evidence, json.loads(self.output.read_text(encoding="utf-8")))
        self.assertEqual(original, self.source.read_bytes())
        self.assertEqual([], list(self.directory.glob(".ipa-reference-*.tmp")))

    def test_existing_output_and_source_destinations_are_never_overwritten(self):
        self.source.write_bytes(ipa_bytes())
        self.output.write_text("prior evidence", encoding="utf-8")
        for destination in (self.output, self.source):
            with self.subTest(destination=destination):
                before = destination.read_bytes()
                with self.assertRaises(audit.AuditError):
                    audit.write_evidence(self.source, destination)
                self.assertEqual(before, destination.read_bytes())

    def test_destination_suffix_parent_and_symlinks_are_checked(self):
        self.source.write_bytes(ipa_bytes())
        for destination in (self.directory / "unexpected.ipa", self.directory / "missing" / "out.json"):
            with self.assertRaises((audit.AuditError, OSError)):
                audit.write_evidence(self.source, destination)
        link = self.directory / "linked.json"
        try:
            link.symlink_to(self.source)
        except OSError:
            return  # Windows commonly disallows symlink creation for this user.
        with self.assertRaises(audit.AuditError):
            audit.write_evidence(self.source, link)

    def test_destination_created_concurrently_is_preserved(self):
        self.source.write_bytes(ipa_bytes())
        original_audit = audit.audit_ipa

        def raced_audit(*args, **kwargs):
            result = original_audit(*args, **kwargs)
            self.output.write_text("other writer", encoding="utf-8")
            return result

        with mock.patch.object(audit, "audit_ipa", side_effect=raced_audit):
            with self.assertRaises(audit.AuditError):
                audit.write_evidence(self.source, self.output)
        self.assertEqual("other writer", self.output.read_text(encoding="utf-8"))
        self.assertEqual([], list(self.directory.glob(".ipa-reference-*.tmp")))

    def test_source_changed_during_audit_discards_evidence(self):
        self.source.write_bytes(ipa_bytes())
        original_inventory = audit._inventory

        def changed_inventory(*args, **kwargs):
            result = original_inventory(*args, **kwargs)
            if kwargs.get("backend"):
                # Simulate replacement without trying to modify an open Windows file.
                result["simulated_mutation"] = True
            return result

        signature = audit._signature(self.source)
        with mock.patch.object(audit, "_signature", side_effect=[signature, (*signature[:-1], signature[-1] + 1)]):
            with mock.patch.object(audit, "_inventory", side_effect=changed_inventory):
                with self.assertRaises(audit.AuditError):
                    audit.write_evidence(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_cli_requires_explicit_output_and_reports_static_scope(self):
        self.source.write_bytes(ipa_bytes())
        with mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            self.assertEqual(0, audit.main([str(self.source), "--output", str(self.output)]))
        self.assertFalse(json.loads(stdout.getvalue())["runtime_verified"])
        with mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            self.assertEqual(1, audit.main([str(self.source), "--output", str(self.output)]))
        self.assertIn("Refusing to overwrite", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
