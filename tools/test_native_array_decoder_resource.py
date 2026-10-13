"""The Dex2jar array template must survive dependency filtering byte for byte."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from native_extension_engine import build


class NativeArrayDecoderResourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.current = self.root / "current.jar"
        self.legacy = self.root / "legacy.jar"
        self.output = self.root / "dependency.jar"
        with zipfile.ZipFile(self.legacy, "w") as jar:
            jar.writestr("LICENSE", "Fixture license")
        self.patchers = [
            patch.object(build, "verify_dependency_archive"),
            patch.object(build, "LEGACY_DEPENDENCY_BYTES", self.legacy.stat().st_size),
            patch.object(build, "LEGACY_DEPENDENCY_SHA256", build.sha256(self.legacy)),
        ]
        for patcher in self.patchers:
            patcher.start()
            self.addCleanup(patcher.stop)

    def archive(self, template):
        with zipfile.ZipFile(self.current, "w") as jar:
            jar.writestr("com/googlecode/d2j/Fixture.class", b"\xca\xfe\xba\xbe\x00\x00\x00\x34fixture")
            if template is not None:
                jar.writestr("res/Hex.class", template)

    def test_template_outside_class_prefix_is_retained_exactly(self):
        template = b"\xca\xfe\xba\xbe\x00\x00\x00\x34array-template-byte-content"
        self.archive(template)
        proof = build.build_dependencies(self.current, self.output, self.legacy)
        with zipfile.ZipFile(self.output) as jar:
            self.assertEqual(template, jar.read("res/Hex.class"))
            self.assertIsNone(jar.testzip())
        self.assertEqual(2, proof["classes"])

    def test_missing_template_fails_build_instead_of_broken_extension_jars(self):
        self.archive(None)
        with self.assertRaisesRegex(ValueError, "array decoder template is missing"):
            build.build_dependencies(self.current, self.output, self.legacy)

    def test_template_is_also_checked_for_java8_class_version(self):
        self.archive(b"\xca\xfe\xba\xbe\x00\x00\x00\x3djava17-template")
        with self.assertRaisesRegex(ValueError, "newer than.*Java 8"):
            build.build_dependencies(self.current, self.output, self.legacy)

    def test_nonclass_template_bytes_are_rejected(self):
        self.archive(b"not-a-java-class")
        with self.assertRaisesRegex(ValueError, "Invalid dependency class"):
            build.build_dependencies(self.current, self.output, self.legacy)


if __name__ == "__main__":
    unittest.main()
