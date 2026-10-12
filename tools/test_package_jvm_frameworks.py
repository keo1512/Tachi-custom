"""Cross-platform structural tests; they do not execute/sign iOS native code."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import package_jvm_frameworks as packaging
from configure_ios_tachi_runtime import macho


def string_command(command: int, text: str) -> bytes:
    payload = text.encode() + b"\0"
    size = (24 + len(payload) + 7) & ~7
    return struct.pack("<IIIIII", command, size, 24, 0, 0x10000, 0x10000) + payload + bytes(size - 24 - len(payload))


def image(identifier: str, dependencies: list[str], file_type: int = 6) -> bytes:
    commands = [struct.pack("<IIIIII", 0x32, 24, 2, 0xF0000, 0xF0000, 0),
                string_command(0xD, identifier)]
    commands.extend(string_command(0xC, value) for value in dependencies)
    payload = b"".join(commands)
    return struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, file_type, len(commands), len(payload), 0, 0) + payload


def rewrite(command: list[str], check: bool) -> None:
    assert check and command[:2] == ["xcrun", "install_name_tool"]
    path = Path(command[-1])
    native = macho(path)
    identifier = native["id"]
    dependencies = native["dependencies"]
    index = 2
    while index < len(command) - 1:
        if command[index] == "-id":
            identifier = command[index + 1]
            index += 2
        elif command[index] == "-change":
            old, new = command[index + 1:index + 3]
            dependencies = [new if value == old else value for value in dependencies]
            index += 3
        else:
            raise AssertionError("Unexpected native rewrite option")
    path.write_bytes(image(identifier, dependencies))


class FrameworkPackagingTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Runner.app"
        self.bundle = self.app / "Frameworks/tachi_runtime.framework/TachiRuntime.bundle"
        self.jre = self.bundle / "jre"
        self.manifest = self.bundle / "licenses/upstream-provenance.json"
        self.manifest.parent.mkdir(parents=True)
        libraries = {}
        for relative in packaging.FRAMEWORK_NAMES:
            source = self.jre / relative
            source.parent.mkdir(parents=True, exist_ok=True)
            dependencies = ["/usr/lib/libSystem.B.dylib"]
            if relative == "lib/server/libjvm.dylib":
                dependencies.insert(0, "@loader_path/libffi.8.dylib")
            elif relative == "lib/libjava.dylib":
                dependencies[:0] = ["@loader_path/server/libjvm.dylib", "@loader_path/libverify.dylib"]
            elif relative != "lib/server/libffi.8.dylib":
                dependencies[:0] = ["@loader_path/server/libjvm.dylib", "@loader_path/libjava.dylib"]
            source.write_bytes(image("@rpath/" + source.name, dependencies))
            libraries[relative] = {"file": relative, "sha256": packaging.sha256(source),
                                   "installNamesPatched": True}
        self.provenance = {"nativeLibraries": list(libraries.values()), "deviceRuntimeVerified": False}
        self.manifest.write_text(json.dumps(self.provenance), encoding="utf-8")
        self.original_manifest = self.manifest.read_bytes()
        self.original_bytes = {relative: (self.jre / relative).read_bytes() for relative in libraries}
        self.data = {"lib/rt.jar": b"bootstrap fixture", "lib/resources.jar": b"bootstrap resources",
                     "lib/jsse.jar": b"security bootstrap", "lib/security/cacerts": b"trust store fixture",
                     "lib/security/java.security": b"security config", "lib/ext/sunec.jar": b"provider fixture"}
        for relative, data in self.data.items():
            target = self.jre / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        # Windows on this host cannot create symlinks without a privilege. Keep
        # real file bytes/renames/rollback, and model only POSIX alias operations
        # in tests. On macOS these same tests use actual filesystem symlinks.
        if os.name == "nt":
            aliases = {}
            original_resolve = Path.resolve
            original_unlink = Path.unlink
            original_link = Path.is_symlink
            original_readlink = os.readlink
            def key(value):
                return Path(value).absolute()
            def symlink(path, target, target_is_directory=False):
                with path.open("xb"):
                    pass
                aliases[key(path)] = str(target)
            def is_link(path):
                return key(path) in aliases or original_link(path)
            def resolve(path, strict=False):
                target = aliases.get(key(path))
                if target is not None:
                    value = Path(target)
                    return original_resolve(value if value.is_absolute() else path.parent / value, strict=strict)
                return original_resolve(path, strict=strict)
            def unlink(path, missing_ok=False):
                aliases.pop(key(path), None)
                return original_unlink(path, missing_ok=missing_ok)
            def readlink(path, **kwargs):
                target = aliases.get(key(path))
                return target if target is not None else original_readlink(path, **kwargs)
            for object_, name, replacement in [(Path, "symlink_to", symlink), (Path, "is_symlink", is_link),
                                                (Path, "resolve", resolve), (Path, "unlink", unlink),
                                                (os, "readlink", readlink)]:
                stub = patch.object(object_, name, replacement)
                stub.start()
                self.addCleanup(stub.stop)

    def run_package(self, rewrite_tool=rewrite) -> dict:
        with patch.object(packaging.sys, "platform", "darwin"), patch.object(packaging.subprocess, "run", side_effect=rewrite_tool):
            return packaging.package(self.app)

    def assert_original(self) -> None:
        self.assertEqual(self.manifest.read_bytes(), self.original_manifest)
        for relative, data in self.original_bytes.items():
            self.assertEqual((self.jre / relative).read_bytes(), data)
        self.assertFalse(list((self.app / "Frameworks").glob(".jvm-packaging-*")))
        for relative, name in packaging.FRAMEWORK_NAMES.items():
            self.assertFalse((self.app / "Frameworks" / f"{name}.framework").exists())
            self.assertFalse((self.app / packaging.alias_path(relative)).is_symlink())

    def test_nine_flat_frameworks_aliases_dependency_names_and_bootstrap_preserved(self) -> None:
        result = self.run_package()
        self.assertEqual(result, {"nativeLayoutVersion": 2, "frameworks": 9, "deviceRuntimeVerified": False})
        current = json.loads(self.manifest.read_text())
        records = packaging.native_records(current)
        for relative, name in packaging.FRAMEWORK_NAMES.items():
            binary = self.app / packaging.executable_path(relative)
            alias = self.app / packaging.alias_path(relative)
            self.assertEqual(os.readlink(alias), f"{name}.framework/{name}")
            self.assertEqual(alias.resolve(), binary.resolve())
            self.assertFalse((self.jre / relative).exists())
            self.assertEqual(records[relative]["originalSha256"], hashlib.sha256(self.original_bytes[relative]).hexdigest())
            self.assertEqual(records[relative]["sha256"], packaging.sha256(binary))
            native = macho(binary)
            self.assertEqual(native["id"], f"@rpath/{name}.framework/{name}")
            for dependency in native["dependencies"]:
                if dependency.startswith("@loader_path/"):
                    target = binary.parent / dependency.removeprefix("@loader_path/")
                    self.assertTrue(target.is_file())
                    self.assertEqual(target.parent.suffix, ".framework")
            with (binary.parent / "Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            self.assertEqual(info["CFBundlePackageType"], "FMWK")
            self.assertEqual(info["CFBundleExecutable"], name)
        for relative, data in self.data.items():
            self.assertEqual((self.jre / relative).read_bytes(), data)

    def test_completed_layout_is_idempotent_and_still_checked(self) -> None:
        self.run_package()
        with patch.object(packaging.sys, "platform", "darwin"), patch.object(packaging.subprocess, "run") as tool:
            self.assertEqual(packaging.package(self.app)["frameworks"], 9)
            tool.assert_not_called()
        binary = self.app / packaging.executable_path("lib/libnet.dylib")
        binary.write_bytes(binary.read_bytes() + b"tampered")
        with self.assertRaisesRegex(ValueError, "provenance"):
            self.run_package()

    def test_tool_failure_never_removes_the_prepared_sources(self) -> None:
        count = 0
        def fail(command, check):
            nonlocal count
            count += 1
            if count == 4:
                raise subprocess.CalledProcessError(1, command)
            rewrite(command, check)
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_package(fail)
        self.assert_original()

    def test_late_layout_failure_restores_deleted_sources_and_original_manifest(self) -> None:
        def wrong_install_name(command, check):
            rewrite(command, check)
            binary = Path(command[-1])
            if binary.name == "TachiNet":
                native = macho(binary)
                binary.write_bytes(image("@rpath/foreign-name.dylib", native["dependencies"]))
        with self.assertRaisesRegex(ValueError, "install name"):
            self.run_package(wrong_install_name)
        self.assert_original()

    def test_alias_creation_failure_rolls_back_already_committed_frameworks(self) -> None:
        symlink = Path.symlink_to
        count = 0
        def fail(path, target, target_is_directory=False):
            nonlocal count
            count += 1
            if count == 3:
                raise OSError("simulated alias creation failure")
            return symlink(path, target, target_is_directory)
        with patch.object(Path, "symlink_to", fail), self.assertRaisesRegex(OSError, "simulated"):
            self.run_package()
        self.assert_original()

    def test_duplicate_native_record_is_rejected(self) -> None:
        self.provenance["nativeLibraries"][-1] = self.provenance["nativeLibraries"][0]
        self.manifest.write_text(json.dumps(self.provenance))
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.run_package()
        self.assertTrue((self.jre / "lib/server/libjvm.dylib").is_file())

    def test_missing_native_or_hash_mismatch_is_rejected_before_tools(self) -> None:
        source = self.jre / "lib/libnet.dylib"
        source.unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            self.run_package()
        source.write_bytes(self.original_bytes["lib/libnet.dylib"] + b"modified")
        with self.assertRaisesRegex(ValueError, "provenance"):
            self.run_package()

    def test_native_source_symlink_escape_is_rejected(self) -> None:
        source = self.jre / "lib/libnet.dylib"
        outside = self.app.parent / "outside-native.dylib"
        outside.write_bytes(source.read_bytes())
        source.unlink()
        source.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "escapes"):
            self.run_package()
        self.assertEqual(outside.read_bytes(), self.original_bytes["lib/libnet.dylib"])

    def test_duplicate_resource_bundle_and_existing_destination_are_rejected(self) -> None:
        duplicate = self.app / "TachiRuntime.bundle"
        duplicate.mkdir()
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.run_package()
        duplicate.rmdir()
        existing = self.app / "Frameworks/TachiNet.framework"
        existing.mkdir()
        (existing / "user-file").write_bytes(b"keep")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.run_package()
        self.assertEqual((existing / "user-file").read_bytes(), b"keep")

    def test_layout_rejects_an_alias_redirected_outside_app(self) -> None:
        self.run_package()
        alias = self.app / packaging.alias_path("lib/libnet.dylib")
        alias.unlink()
        outside = self.app.parent / "foreign.dylib"
        outside.write_bytes(b"do not load")
        alias.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "relative"):
            self.run_package()
        self.assertEqual(outside.read_bytes(), b"do not load")

    def test_layout_rejects_a_missing_alias(self) -> None:
        self.run_package()
        alias = self.app / packaging.alias_path("lib/libnet.dylib")
        alias.unlink()
        with self.assertRaisesRegex(ValueError, "alias is missing"):
            self.run_package()

    def test_unresolved_native_dependency_never_changes_original_sources(self) -> None:
        relative = "lib/libnet.dylib"
        source = self.jre / relative
        source.write_bytes(image("@rpath/libnet.dylib", ["@loader_path/missing.dylib"]))
        self.original_bytes[relative] = source.read_bytes()
        for record in self.provenance["nativeLibraries"]:
            if record["file"] == relative:
                record["sha256"] = packaging.sha256(source)
        self.manifest.write_text(json.dumps(self.provenance))
        self.original_manifest = self.manifest.read_bytes()
        with self.assertRaisesRegex(ValueError, "dependency is not"):
            self.run_package()
        self.assert_original()

    def test_non_macos_packaging_is_rejected_without_mutation(self) -> None:
        with patch.object(packaging.sys, "platform", "win32"), self.assertRaisesRegex(ValueError, "macOS"):
            packaging.package(self.app)
        self.assert_original()


if __name__ == "__main__":
    unittest.main()
