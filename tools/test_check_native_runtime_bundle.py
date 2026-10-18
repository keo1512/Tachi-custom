"""Packaging checks use synthetic bytes; they never claim native execution."""
import json
import hashlib
import io
import os
from pathlib import Path
import stat
import struct
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_native_runtime_bundle import verify, verify_archive, BOOTSTRAP_JARS, sha256
import check_native_runtime_bundle as bundle_checker
import test_package_jvm_frameworks as framework_fixtures


def native_bytes(platform=2, dependency=None):
    commands = struct.pack("<IIIIII", 0x32, 24, platform, 0x0f0000, 0x1b0000, 0)
    count = 1
    if dependency:
        name = dependency.encode() + b"\0"
        size = (24 + len(name) + 7) // 8 * 8
        commands += struct.pack("<IIIIII", 0xC, size, 24, 0, 0, 0) + name + bytes(size - 24 - len(name))
        count += 1
    return struct.pack("<IiiIIIII", 0xfeedfacf, 0x100000c, 0, 6, count, len(commands), 0, 0) + commands


class RuntimeBundleTest(unittest.TestCase):
    def setUp(self):
        self.array_template = b"\xca\xfe\xba\xbe\x00\x00\x00\x34" + b"fixture" + bytes(2326 - 15)
        expected = mock.patch.object(bundle_checker, "ARRAY_DECODER_SHA256", hashlib.sha256(self.array_template).hexdigest())
        expected.start()
        self.addCleanup(expected.stop)
        # Reuse the actual structural fixture/alias model, without inheriting
        # its unit tests. Windows models POSIX aliases; macOS uses real aliases.
        fixture = framework_fixtures.FrameworkPackagingTest("test_nine_flat_frameworks_aliases_dependency_names_and_bootstrap_preserved")
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.run_package()
        self.app = fixture.app
        self.tachi = fixture.bundle
        self.vbook = self.app / "VbookRuntime.bundle"
        (self.tachi / "engine").mkdir(parents=True)
        self.vbook.mkdir()
        (self.vbook / "host.js").write_text("function __runVbook() {}")
        self.provenance = json.loads(fixture.manifest.read_text())
        for name, key, member in (("extension-host.jar", "host", "dev/tachibooks/engine/ExtensionHost.class"),
                                  ("extension-dependencies.jar", "dependencies", "fixture-only.txt")):
            path = self.tachi / "engine" / name
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr(member, b"fixture only")
                if key == "dependencies":
                    archive.writestr("res/Hex.class", self.array_template)
            self.provenance[key] = {"sha256": sha256(path)}
        for name in BOOTSTRAP_JARS:
            self.write_jar(self.tachi / "jre/lib" / name, "java/lang/Object.class" if name == "rt.jar" else "fixture-only.txt")
        extension = self.tachi / "jre/lib/ext"
        for name in ("sunec.jar", "sunjce_provider.jar"):
            self.write_jar(extension / name)
        (self.tachi / "jre/lib/security/java.policy").write_text("fixture only")
        (self.tachi / "licenses/SOURCE.txt").write_text("fixture only")
        self.write_provenance()
        for name in ("tachi_runtime", "vbook_runtime"):
            path = self.app / "Frameworks" / (name + ".framework") / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(native_bytes())

    def write_jar(self, path, member="fixture-only.txt"):
        path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(member, b"fixture only")

    def write_provenance(self):
        (self.tachi / "licenses/upstream-provenance.json").write_text(json.dumps(self.provenance))

    def test_complete_package_reports_resources_without_claiming_device_execution(self):
        result = verify(self.app)
        self.assertEqual(result["nativeLibraries"], 9)
        self.assertEqual(result["nativeLayoutVersion"], 2)
        self.assertEqual(result["bootstrapJars"], 6)
        self.assertFalse(result["deviceRuntimeVerified"])

    def test_current_image_host_requires_separate_pinned_signed_crypto_provider(self):
        path = self.tachi / "engine/extension-host.jar"
        with zipfile.ZipFile(path, "a") as archive:
            archive.writestr("dev/tachibooks/engine/ImageCodec.class", b"fixture only")
        self.provenance["host"]["sha256"] = sha256(path)
        self.write_provenance()
        with self.assertRaisesRegex(ValueError, "crypto provider provenance"):
            verify(self.app)
        provider = self.tachi / "engine/bcprov.jar"
        with zipfile.ZipFile(provider, "w") as archive:
            archive.writestr("org/bouncycastle/jce/provider/BouncyCastleProvider.class", b"fixture only")
            archive.writestr("META-INF/fixture.SF", b"fixture only; not a runtime signature")
        record = {"bytes": provider.stat().st_size, "sha256": sha256(provider)}
        # Only a synthetic pin is overridden in this structural fixture. The
        # original APK proof runs the untouched upstream signed provider.
        with mock.patch.dict(bundle_checker.SPEC, {"cryptoProvider": record}):
            self.provenance["cryptoProvider"] = record
            self.write_provenance()
            verify(self.app)
            data = bytearray(provider.read_bytes())
            data[-1] ^= 1
            provider.write_bytes(data)
            with self.assertRaisesRegex(ValueError, "crypto provider bytes"):
                verify(self.app)

    def test_missing_or_changed_array_decoder_fails_even_with_updated_jar_provenance(self):
        path = self.tachi / "engine/extension-dependencies.jar"
        for payload in (None, b"wrong size", self.array_template[:-1] + b"x", self.array_template[:6] + b"\x00\x3d" + self.array_template[8:]):
            with self.subTest(payload=None if payload is None else len(payload)):
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr("fixture-only.txt", b"fixture only")
                    if payload is not None:
                        archive.writestr("res/Hex.class", payload)
                self.provenance["dependencies"]["sha256"] = sha256(path)
                self.write_provenance()
                with self.assertRaisesRegex(ValueError, "array decoder template"):
                    verify(self.app)

    def test_missing_host_resource_and_duplicate_bundle_fail_before_packaging(self):
        (self.vbook / "host.js").unlink()
        with self.assertRaisesRegex(ValueError, "vBook script host"):
            verify(self.app)
        (self.app / "Frameworks/VbookRuntime.bundle").mkdir()
        with self.assertRaisesRegex(ValueError, "exactly one"):
            verify(self.app)

    def test_unpatched_or_missing_native_library_cannot_be_accepted(self):
        self.provenance["nativeLibraries"][0]["installNamesPatched"] = False
        self.write_provenance()
        with self.assertRaisesRegex(ValueError, "provenance"):
            verify(self.app)
        self.provenance["nativeLibraries"].pop()
        self.write_provenance()
        with self.assertRaisesRegex(ValueError, "incomplete"):
            verify(self.app)

    def test_jar_hash_mismatch_fails_and_simulator_plugin_cannot_be_packaged(self):
        self.provenance["host"]["sha256"] = "0" * 64
        self.write_provenance()
        with self.assertRaisesRegex(ValueError, "provenance"):
            verify(self.app)
        self.provenance["host"]["sha256"] = sha256(self.tachi / "engine/extension-host.jar")
        self.write_provenance()
        (self.app / "Frameworks/vbook_runtime.framework/vbook_runtime").write_bytes(native_bytes(platform=7))
        with self.assertRaisesRegex(ValueError, "simulator"):
            verify(self.app)

    def test_unresolved_dependency_fails_even_when_it_matches_provenance(self):
        record = self.provenance["nativeLibraries"][0]
        path = self.app / record["framework"]
        name = path.name
        path.write_bytes(framework_fixtures.image(f"@rpath/{name}.framework/{name}",
                                                ["@loader_path/../../../../outside.dylib"]))
        record["sha256"] = sha256(path)
        self.write_provenance()
        with self.assertRaisesRegex(ValueError, "escapes"):
            verify(self.app)

    def test_old_resource_native_layout_cannot_be_packaged(self):
        self.provenance.pop("nativeLayoutVersion")
        self.write_provenance()
        with self.assertRaisesRegex(ValueError, "layout version 2"):
            verify(self.app)

    def test_all_six_bootstrap_jars_are_required_and_crc_checked(self):
        for name in BOOTSTRAP_JARS:
            with self.subTest(missing=name):
                path = self.tachi / "jre/lib" / name
                original = path.read_bytes()
                path.unlink()
                try:
                    with self.assertRaisesRegex(ValueError, "bootstrap resource is missing"):
                        verify(self.app)
                finally:
                    path.write_bytes(original)
            with self.subTest(corrupt=name):
                # Stored payload mutation retains a structurally valid ZIP but
                # violates the original CRC, independently of host JAR hashes.
                payload = path.read_bytes()
                corrupted = payload.replace(b"fixture only", b"fixture fail", 1)
                self.assertNotEqual(corrupted, payload)
                path.write_bytes(corrupted)
                try:
                    with self.assertRaisesRegex(ValueError, "CRC"):
                        verify(self.app)
                finally:
                    path.write_bytes(payload)

    def test_rt_jar_must_include_actual_bootstrap_object_member(self):
        self.write_jar(self.tachi / "jre/lib/rt.jar")
        with self.assertRaisesRegex(ValueError, "bootstrap resource is incomplete"):
            verify(self.app)

    def test_security_resources_and_extension_providers_are_required(self):
        security = self.tachi / "jre/lib/security"
        for name in ("cacerts", "java.security", "java.policy"):
            with self.subTest(security=name):
                path = security / name
                payload = path.read_bytes()
                path.write_bytes(b"")
                with self.assertRaisesRegex(ValueError, "security resource is missing"):
                    verify(self.app)
                path.write_bytes(payload)
        for name in ("sunec.jar", "sunjce_provider.jar"):
            with self.subTest(provider=name):
                path = self.tachi / "jre/lib/ext" / name
                payload = path.read_bytes()
                path.unlink()
                with self.assertRaisesRegex(ValueError, "bootstrap resource is missing"):
                    verify(self.app)
                path.write_bytes(payload)

    def test_missing_or_absolute_native_alias_fails_real_layout_check(self):
        record = self.provenance["nativeLibraries"][0]
        alias = self.app / record["alias"]
        target = os.readlink(alias)
        alias.unlink()
        with self.assertRaisesRegex(ValueError, "alias is missing"):
            verify(self.app)
        alias.symlink_to(self.app / record["framework"])
        with self.assertRaisesRegex(ValueError, "relative target"):
            verify(self.app)
        alias.unlink()
        alias.symlink_to(target)

    def test_any_frameworks_symlink_must_stay_in_frameworks(self):
        outside = self.app / "outside-resource"
        outside.write_bytes(b"keep")
        alias = self.app / "Frameworks/unexpected-alias"
        alias.symlink_to("../outside-resource")
        with self.assertRaisesRegex(ValueError, "escapes the Frameworks"):
            verify(self.app)
        self.assertEqual(outside.read_bytes(), b"keep")

    def test_leftover_standalone_native_resource_cannot_be_accepted(self):
        record = self.provenance["nativeLibraries"][0]
        path = self.tachi / "jre" / record["file"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"unexpected standalone code")
        with self.assertRaisesRegex(ValueError, "Standalone JVM native code"):
            verify(self.app)


class RuntimeArchiveTest(unittest.TestCase):
    def setUp(self):
        fixture = RuntimeBundleTest("test_complete_package_reports_resources_without_claiming_device_execution")
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        self.ipa = fixture.app.parent / "fixture.ipa"
        self.records = fixture.provenance["nativeLibraries"]
        self.resource = "Payload/Runner.app/" + fixture.tachi.relative_to(fixture.app).as_posix() + "/"
        self.entries = {"Payload/Runner.app/Info.plist": (stat.S_IFREG, b"fixture")}
        for path in fixture.app.rglob("*"):
            name = "Payload/Runner.app/" + path.relative_to(fixture.app).as_posix()
            if path.is_symlink():
                self.entries[name] = (stat.S_IFLNK, os.readlink(path).encode())
            elif path.is_file():
                self.entries[name] = (stat.S_IFREG, path.read_bytes())

    def write_archive(self, entries=None):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            for name, (mode, payload) in (entries or self.entries).items():
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = (mode | 0o755) << 16
                archive.writestr(entry, payload)

    def test_final_zip_preserves_all_nine_native_aliases_and_hashes(self):
        self.write_archive()
        result = verify_archive(self.ipa)
        self.assertEqual(result["nativeAliases"], 9)
        self.assertTrue(result["zipIntegrityVerified"])
        self.assertFalse(result["deviceRuntimeVerified"])

    def test_final_zip_rejects_lost_template_even_when_all_jar_and_outer_hashes_match(self):
        dependency_name = self.resource + "engine/extension-dependencies.jar"
        manifest_name = self.resource + "licenses/upstream-provenance.json"
        for template in (None, b"wrong-size", b"x" * 2326):
            with self.subTest(template=None if template is None else len(template)):
                payload = io.BytesIO()
                with zipfile.ZipFile(payload, "w") as archive:
                    archive.writestr("fixture-only.txt", b"fixture only")
                    if template is not None:
                        archive.writestr("res/Hex.class", template)
                entries = dict(self.entries)
                entries[dependency_name] = (stat.S_IFREG, payload.getvalue())
                manifest = json.loads(entries[manifest_name][1])
                manifest["dependencies"]["sha256"] = hashlib.sha256(payload.getvalue()).hexdigest()
                entries[manifest_name] = (stat.S_IFREG, json.dumps(manifest).encode())
                self.write_archive(entries)
                with self.assertRaisesRegex(ValueError, "array decoder template"):
                    verify_archive(self.ipa)

    def test_each_alias_must_remain_a_symlink_instead_of_copied_binary_bytes(self):
        for record in self.records:
            with self.subTest(library=record["file"]):
                entries = dict(self.entries)
                name = "Payload/Runner.app/" + record["alias"]
                entries[name] = entries["Payload/Runner.app/" + record["framework"]]
                self.write_archive(entries)
                with self.assertRaisesRegex(ValueError, "symlink alias"):
                    verify_archive(self.ipa)

    def test_missing_absolute_or_wrong_native_alias_target_is_rejected(self):
        name = "Payload/Runner.app/" + self.records[0]["alias"]
        for target in (None, b"/private/outside", b"../outside", b"TachiJava.framework/TachiJava"):
            with self.subTest(target=target):
                entries = dict(self.entries)
                if target is None:
                    entries.pop(name)
                else:
                    entries[name] = (stat.S_IFLNK, target)
                self.write_archive(entries)
                with self.assertRaisesRegex(ValueError, "alias"):
                    verify_archive(self.ipa)

    def test_changed_native_or_host_bytes_cannot_pass_outer_zip_crc(self):
        names = ["Payload/Runner.app/" + self.records[0]["framework"],
                 self.resource + "engine/extension-host.jar"]
        for name in names:
            with self.subTest(resource=name):
                entries = dict(self.entries)
                entries[name] = (stat.S_IFREG, b"changed bytes with a valid outer ZIP CRC")
                self.write_archive(entries)
                with self.assertRaisesRegex(ValueError, "prepared provenance"):
                    verify_archive(self.ipa)

    def test_duplicate_provenance_or_zip_entry_and_standalone_code_are_rejected(self):
        manifest = self.resource + "licenses/upstream-provenance.json"
        entries = dict(self.entries)
        entries["Payload/Runner.app/Extra/TachiRuntime.bundle/licenses/upstream-provenance.json"] = entries[manifest]
        self.write_archive(entries)
        with self.assertRaisesRegex(ValueError, "exactly one"):
            verify_archive(self.ipa)
        self.write_archive()
        with zipfile.ZipFile(self.ipa, "a") as archive:
            # A second record with the same name must not shadow the checked
            # entry when an installer or ZIP extractor chooses another one.
            with mock.patch("warnings.warn"):
                archive.writestr(manifest, self.entries[manifest][1])
        with self.assertRaisesRegex(ValueError, "duplicate ZIP"):
            verify_archive(self.ipa)
        entries = dict(self.entries)
        entries[self.resource + "jre/" + self.records[0]["file"]] = (stat.S_IFREG, b"leftover")
        self.write_archive(entries)
        with self.assertRaisesRegex(ValueError, "Standalone JVM"):
            verify_archive(self.ipa)


if __name__ == "__main__":
    unittest.main()
