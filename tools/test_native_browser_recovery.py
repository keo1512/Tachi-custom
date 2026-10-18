"""Opt-in real Java host recovery checks; no website requests or native-iOS claims.

Set TACHI_PROOF_DEPENDENCIES to a verified extension-dependencies.jar and provide
TACHI_PROOF_JAVAC/TACHI_PROOF_JAVA (or a JDK on PATH). The host is always rebuilt
from the current reviewed source, rather than using a previously compiled host.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from native_extension_engine.build import build_host


class NativeBrowserRecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        supplied = os.environ.get("TACHI_PROOF_DEPENDENCIES")
        if not supplied:
            raise unittest.SkipTest("Real-host proof requires verified TACHI_PROOF_DEPENDENCIES")
        cls.dependencies = Path(supplied).resolve(strict=True)
        cls.javac = os.environ.get("TACHI_PROOF_JAVAC") or shutil.which("javac")
        cls.java = os.environ.get("TACHI_PROOF_JAVA") or shutil.which("java")
        if not cls.javac or not cls.java:
            raise RuntimeError("Real-host proof requires both a JDK compiler and a Java runtime")
        cls.temporary = tempfile.TemporaryDirectory(prefix="tachi-browser-recovery-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.host = cls.root / "extension-host.jar"
        build_host(cls.dependencies, cls.host, cls.root, cls.javac)
        cls.classes = cls.root / "proof-classes"
        proofs = Path(__file__).parent / "native_extension_engine/proof"
        subprocess.run([
            cls.javac, "--release", "8", "-encoding", "UTF-8", "-cp",
            os.pathsep.join(map(str, [cls.host, cls.dependencies])),
            "-d", str(cls.classes), str(proofs / "BrowserSessionRecoveryProof.java"),
            str(proofs / "ChapterPageIsolationProof.java"),
        ], check=True, timeout=60, capture_output=True, text=True)

    def test_optional_browser_corruption_preserves_bytes_and_allows_restart(self):
        classpath = os.pathsep.join(map(str, [self.classes, self.host, self.dependencies]))
        for mode in ("malformed", "oversize", "array", "null", "empty", "unknown", "entry"):
            with self.subTest(mode=mode):
                result = subprocess.run([
                    self.java, "-Xint", "-cp", classpath,
                    "dev.tachibooks.engine.BrowserSessionRecoveryProof",
                    str(self.root / mode), mode,
                ], timeout=45, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("BROWSER_RECOVERY_RESTART_OK", result.stdout)
                self.assertIn("BROWSER_SESSION_RECOVERY_OK mode=" + mode, result.stdout)
                print(result.stdout, end="")

    def test_lazy_page_failure_and_signed_url_rotation_are_isolated(self):
        classpath = os.pathsep.join(map(str, [self.classes, self.host, self.dependencies]))
        for mode, marker in (("eager", "CHAPTER_PAGE_ISOLATION_PROOF_OK"),
                             ("rotated", "ROTATED_PAGE_RETRY_PROOF_OK")):
            with self.subTest(mode=mode):
                result = subprocess.run([
                    self.java, "-Xint", "-cp", classpath,
                    "dev.tachibooks.engine.ChapterPageIsolationProof",
                    str(self.root / mode), mode,
                ], timeout=45, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(marker, result.stdout)
                print(result.stdout, end="")


if __name__ == "__main__":
    unittest.main()
