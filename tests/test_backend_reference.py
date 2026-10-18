"""Failure-path tests for the IPA evidence reader; no Java runtime required."""

import importlib.util
import io
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile


MODULE = Path(__file__).resolve().parents[1] / "scripts/compare_backend_reference.py"
SPEC = importlib.util.spec_from_file_location("backend_reference", MODULE)
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)


def archive(entries):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as result:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            for name, data in entries:
                result.writestr(name, data)
    return zipfile.ZipFile(io.BytesIO(stream.getvalue()))


def minimal_class():
    def utf8(value):
        value = value.encode("ascii")
        return b"\x01" + struct.pack(">H", len(value)) + value

    pool = [utf8("Example"), b"\x07\x00\x01", utf8("java/lang/Object"),
            b"\x07\x00\x03", utf8("call"), utf8("([B)V")]
    return (
        b"\xca\xfe\xba\xbe" + struct.pack(">HHH", 0, 61, 7)
        + b"".join(pool)
        + struct.pack(">HHHHHH", 0x0021, 2, 4, 0, 0, 1)
        + struct.pack(">HHHH", 0x0109, 5, 6, 0)
        + struct.pack(">H", 0)
    )


class ArchiveComparisonTests(unittest.TestCase):
    def test_identical_changed_missing_and_reference_only_are_distinct(self):
        with archive([("same.class", b"same"), ("changed.class", b"before"),
                      ("missing.class", b"source"), ("notice.txt", b"not a class")]) as source:
            with archive([("same.class", b"same"), ("changed.class", b"after"),
                          ("extra.class", b"not part of dependency")]) as reference:
                result = backend.compare_classes(source, reference)
        self.assertEqual((result["class_count"], result["byte_identical"],
                          result["different_bytes"], result["missing_in_ipa"]),
                         (3, 1, 1, 1))
        self.assertEqual([d["class"] for d in result["differences"]],
                         ["changed.class", "missing.class"])
        self.assertIsNone(result["differences"][1]["ipa_sha256"])
        self.assertNotEqual(result["differences"][0]["dependency_sha256"],
                            result["differences"][0]["ipa_sha256"])

    def test_duplicate_dependency_class_is_rejected(self):
        with archive([("A.class", b"a"), ("A.class", b"b")]) as source:
            with archive([]) as reference:
                with self.assertRaisesRegex(ValueError, "Duplicate archive entry"):
                    backend.compare_classes(source, reference)

    def test_duplicate_reference_entry_is_rejected_even_if_not_compared(self):
        with archive([("A.class", b"a")]) as source:
            with archive([("other", b"a"), ("other", b"b")]) as reference:
                with self.assertRaisesRegex(ValueError, "Duplicate archive entry"):
                    backend.compare_classes(source, reference)

    def test_inventory_fingerprint_is_order_independent_but_detects_changes(self):
        def compare(entries):
            with archive(entries) as source:
                with archive([("A.class", b"a"), ("B.class", b"b")]) as reference:
                    return backend.compare_classes(source, reference)["class_inventory_sha256"]

        entries = [("A.class", b"a"), ("B.class", b"b")]
        self.assertEqual(compare(entries), compare(list(reversed(entries))))
        self.assertNotEqual(compare(entries), compare([("A.class", b"x"), ("B.class", b"b")]))


class ClassfileReaderTests(unittest.TestCase):
    def test_native_signature_and_jvm_version_are_read(self):
        parsed = backend.ClassReader(minimal_class()).parse()
        self.assertEqual((parsed["class"], parsed["major_version"]), ("Example", 61))
        method = parsed["methods"][0]
        self.assertEqual((method["name"], method["descriptor"]), ("call", "([B)V"))
        self.assertTrue(method["native"])
        self.assertTrue(method["public"])
        self.assertTrue(method["static"])

    def test_every_truncated_prefix_is_rejected(self):
        data = minimal_class()
        for length in range(len(data)):
            with self.subTest(length=length):
                with self.assertRaises(ValueError):
                    backend.ClassReader(data[:length]).parse()

    def test_unknown_pool_tag_and_trailing_data_are_rejected(self):
        data = minimal_class()
        with self.assertRaisesRegex(ValueError, "Unsupported JVM constant-pool tag"):
            backend.ClassReader(data[:10] + b"\xff" + data[11:]).parse()
        with self.assertRaisesRegex(ValueError, "Trailing bytes"):
            backend.ClassReader(data + b"extra").parse()

    def test_invalid_magic_and_class_index_are_rejected(self):
        data = minimal_class()
        with self.assertRaisesRegex(ValueError, "Invalid JVM classfile magic"):
            backend.ClassReader(b"bad!" + data[4:]).parse()
        # Class header starts 22 bytes from the end; replace this_class with 0.
        corrupt = data[:-20] + b"\x00\x00" + data[-18:]
        with self.assertRaisesRegex(ValueError, "Invalid JVM class name index"):
            backend.ClassReader(corrupt).parse()


class EvidencePublicationTests(unittest.TestCase):
    def test_wrong_reference_hash_is_rejected_before_archive_parsing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "untrusted.ipa"
            path.write_bytes(b"arbitrary file named ipa")
            with self.assertRaisesRegex(ValueError, "IPA SHA-256"):
                backend.build_report(path, Path(directory))

    def test_report_is_written_as_complete_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "evidence.json"
            backend.write_json_atomic(path, {"matched": True, "label": "Tiếng Việt"})
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")),
                             {"matched": True, "label": "Tiếng Việt"})
            self.assertEqual([p.name for p in path.parent.iterdir()], [path.name])


class SourceProvenanceTests(unittest.TestCase):
    def test_changed_missing_and_duplicate_source_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            engine = Path(directory) / "engine"
            engine.mkdir()
            source = engine / "source.kt"
            source.write_bytes(b"original")
            path = Path(directory) / "manifest.json"
            entry = {"path": "source.kt", "sha256": backend.digest(b"original")}
            manifest = {"commit": backend.PINNED_COMMIT,
                        "repository": "https://github.com/tachimanga/Tachidesk-Server",
                        "files": [entry]}
            path.write_text(json.dumps(manifest), encoding="utf-8")
            self.assertTrue(backend.verify_source_manifest(engine, path)[
                "all_tracked_file_hashes_match"])
            source.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "hash differs"):
                backend.verify_source_manifest(engine, path)
            source.unlink()
            with self.assertRaisesRegex(ValueError, "file missing"):
                backend.verify_source_manifest(engine, path)
            source.write_bytes(b"original")
            manifest["files"] = [entry, entry]
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Duplicate source manifest path"):
                backend.verify_source_manifest(engine, path)

    def test_wrong_commit_and_path_outside_engine_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            engine = Path(directory) / "engine"
            engine.mkdir()
            path = Path(directory) / "manifest.json"
            manifest = {"commit": "not the pinned source",
                        "repository": "https://github.com/tachimanga/Tachidesk-Server",
                        "files": [{"path": "../outside.kt", "sha256": "none"}]}
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Unexpected source manifest"):
                backend.verify_source_manifest(engine, path)
            manifest["commit"] = backend.PINNED_COMMIT
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "leaves engine directory"):
                backend.verify_source_manifest(engine, path)


class SourceComparisonConsistencyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.engine = self.root / "engine"
        self.engine.mkdir()
        self.source = self.engine / "source.kt"
        self.source.write_bytes(b"original source")
        self.manifest = self.root / "source-manifest.json"
        self.manifest.write_text(json.dumps({
            "commit": backend.PINNED_COMMIT,
            "repository": "https://github.com/tachimanga/Tachidesk-Server",
            "files": [{"path": "source.kt", "sha256": backend.file_digest(self.source)}],
        }), encoding="utf-8")
        for relative in backend.DEPENDENCIES:
            path = self.engine / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(path, "w") as jar:
                jar.writestr("Example.class", minimal_class())
        nested = io.BytesIO()
        with zipfile.ZipFile(nested, "w") as jar:
            jar.writestr("Example.class", minimal_class())
        self.ipa = self.root / "fixture.ipa"
        with zipfile.ZipFile(self.ipa, "w") as ipa:
            ipa.writestr("Payload/Fixture.app/Info.plist", plistlib.dumps({
                "CFBundleShortVersionString": "5.0", "CFBundleVersion": "511",
                "CFBundleIdentifier": "com.example.fixture",
            }))
            ipa.writestr("Payload/Fixture.app/MCHome.bundle/res.zip", nested.getvalue())

    def report(self):
        return backend.build_report(self.ipa, self.engine, self.manifest,
                                    expected_ipa_sha256=None)

    def test_stable_source_is_reverified_at_end(self):
        result = self.report()
        self.assertTrue(result["source_reference"]["commit_verification"][
            "unchanged_during_comparison"])

    def test_changed_source_during_comparison_discards_evidence(self):
        original_compare = backend.compare_classes

        def mutate_source(*args, **kwargs):
            result = original_compare(*args, **kwargs)
            self.source.write_bytes(b"changed while comparing")
            return result

        with patch.object(backend, "compare_classes", side_effect=mutate_source):
            with self.assertRaisesRegex(ValueError, "hash differs"):
                self.report()

    def test_changed_manifest_with_still_valid_files_is_rejected(self):
        original_compare = backend.compare_classes

        def mutate_manifest(*args, **kwargs):
            result = original_compare(*args, **kwargs)
            text = self.manifest.read_text(encoding="utf-8")
            self.manifest.write_text(text + "\n", encoding="utf-8")
            return result

        with patch.object(backend, "compare_classes", side_effect=mutate_manifest):
            with self.assertRaisesRegex(ValueError, "Source manifest changed"):
                self.report()


class EvidencePublicationFailureTests(unittest.TestCase):
    def test_failed_publication_preserves_prior_evidence_and_cleans_temporary(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "evidence.json"
            path.write_text('{"old":true}', encoding="utf-8")
            with patch.object(backend.os, "replace", side_effect=OSError("disk failure")):
                with self.assertRaisesRegex(OSError, "disk failure"):
                    backend.write_json_atomic(path, {"new": True})
            self.assertEqual(path.read_text(encoding="utf-8"), '{"old":true}')
            self.assertEqual([p.name for p in path.parent.iterdir()], [path.name])


if __name__ == "__main__":
    unittest.main()
