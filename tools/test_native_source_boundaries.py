"""Opt-in Java8 source boundary regressions using current source and loopback.

Use verified TACHI_PROOF_DEPENDENCIES and TACHI_PROOF_JAVAC/TACHI_PROOF_JAVA.
Most cases use synthetic source fixtures. The optional cache-repair case loads
the unchanged original Komga APK; none execute an iPhone runtime. Lazy-page and
browser-corruption cases also run in test_native_browser_recovery.py.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from native_extension_engine.build import build_host


class NativeSourceBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        supplied = os.environ.get("TACHI_PROOF_DEPENDENCIES")
        if not supplied:
            raise unittest.SkipTest("Real-host proof requires verified TACHI_PROOF_DEPENDENCIES")
        cls.dependencies = Path(supplied).resolve(strict=True)
        cls.javac = os.environ.get("TACHI_PROOF_JAVAC") or shutil.which("javac")
        cls.java = os.environ.get("TACHI_PROOF_JAVA") or shutil.which("java")
        if not cls.javac or not cls.java:
            raise RuntimeError("A JDK compiler and Java8 runtime are required")
        cls.temporary = tempfile.TemporaryDirectory(prefix="tachi-source-boundaries-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.host = cls.root / "extension-host.jar"
        build_host(cls.dependencies, cls.host, cls.root, cls.javac)
        cls.classes = cls.root / "proof-classes"
        proof_root = Path(__file__).parent / "native_extension_engine/proof"
        proofs = [proof_root / name for name in (
            "ChapterPageIsolationProof.java", "BrowserSessionIsolationProof.java", "CoverImageProof.java", "PersistentCookieProof.java", "ExtensionVersionProof.java", "PreferenceReloadProof.java", "ExtensionCacheRepairProof.java", "BrowserSeedProof.java", "BrowserCookieAtomicProof.java", "SourceContextAndGraphicsProof.java"
        )]
        subprocess.run([
            cls.javac, "--release", "8", "-encoding", "UTF-8", "-cp",
            os.pathsep.join(map(str, [cls.host, cls.dependencies])),
            "-d", str(cls.classes), *map(str, proofs),
        ], check=True, timeout=60, capture_output=True, text=True)

    def run_proof(self, name, mode, marker):
        classpath = os.pathsep.join(map(str, [self.classes, self.host, self.dependencies]))
        arguments = [str(self.root / name)] + ([mode] if mode else [])
        result = subprocess.run([
            self.java, "-Xint", "-cp", classpath, "dev.tachibooks.engine." + name, *arguments,
        ], timeout=45, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(marker, result.stdout)
        print(result.stdout, end="")

    def test_rotated_cdn_retry_keeps_source_page_identity_and_negative_guards(self):
        self.run_proof("ChapterPageIsolationProof", "rotated", "ROTATED_PAGE_RETRY_PROOF_OK")

    def test_parent_memo_and_original_page_are_isolated_for_identical_short_chapter_ids(self):
        self.run_proof("SourceContextAndGraphicsProof", "context", "SOURCE_CONTEXT_ISOLATION_OK")

    def test_portable_bitmap_contracts_and_strip_pixel_copy(self):
        self.run_proof("SourceContextAndGraphicsProof", "graphics", "PORTABLE_GRAPHICS_OK")

    def test_later_page_request_hook_cannot_break_chapter_opening(self):
        self.run_proof("ChapterPageIsolationProof", "headers", "PAGE_REQUEST_HOOK_ISOLATION_OK")

    def test_original_ipa_extension_library_version_boundaries(self):
        self.run_proof("ExtensionVersionProof", "", "EXTENSION_VERSION_PROOF_OK")

    def test_source_constructor_failure_rolls_back_preference_and_keeps_source_usable(self):
        self.run_proof("PreferenceReloadProof", "", "PREFERENCE_RELOAD_ROLLBACK_OK")

    def test_browser_user_agents_are_isolated_through_real_redirects(self):
        self.run_proof("BrowserSessionIsolationProof", "user-agent", "BROWSER_SESSION_ISOLATION_OK")

    def test_existing_cover_headers_bounds_parallelism_and_page_hook_isolation(self):
        self.run_proof("CoverImageProof", "", "JAVA8_COVER_IMAGE_PROOF_OK")

    def test_http_cookies_survive_reload_expiry_cold_jvm_and_storage_failures(self):
        self.run_proof("PersistentCookieProof", "", "PERSISTENT_COOKIE_PROOF_OK")

    def test_browser_snapshot_cannot_replace_a_refreshed_http_cookie(self):
        self.run_proof("BrowserSessionIsolationProof", "refresh", "BROWSER_SESSION_ISOLATION_OK")

    def test_original_apk_browser_seed_preserves_scope_and_rejects_stale_sessions(self):
        supplied = os.environ.get("TACHI_ORIGINAL_KOMGA_APK")
        if not supplied:
            self.skipTest("Requires original IPA Komga APK")
        self.run_proof("BrowserSeedProof", str(Path(supplied).resolve(strict=True)), "BROWSER_SEED_PROOF_OK")

    def test_browser_seed_snapshot_and_token_are_one_atomic_capture(self):
        self.run_proof("BrowserCookieAtomicProof", "seed", "BROWSER_COOKIE_ATOMIC_OK")

    def test_browser_apply_keeps_concurrent_http_refresh(self):
        self.run_proof("BrowserCookieAtomicProof", "apply", "BROWSER_COOKIE_ATOMIC_OK")

    def test_explicit_browser_save_rolls_back_both_private_stores_on_error(self):
        self.run_proof("BrowserCookieAtomicProof", "persistence", "BROWSER_COOKIE_ATOMIC_OK")

    def test_original_apk_reinstall_repairs_cache_and_preserves_failed_update(self):
        supplied = os.environ.get("TACHI_ORIGINAL_KOMGA_APK")
        if not supplied:
            self.skipTest("Requires the original IPA Komga1.4.47 via TACHI_ORIGINAL_KOMGA_APK")
        apk = Path(supplied).resolve(strict=True)
        classpath = os.pathsep.join(map(str, [self.classes, self.host, self.dependencies]))
        for mode in ("malformed", "validzip", "apk"):
            with self.subTest(mode=mode):
                result = subprocess.run([
                    self.java, "-Xint", "-cp", classpath,
                    "dev.tachibooks.engine.ExtensionCacheRepairProof",
                    str(self.root / ("cache-repair-" + mode)), str(apk), mode,
                ], timeout=60, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("EXTENSION_CACHE_REPAIR_OK mode=" + mode, result.stdout)
                print(result.stdout, end="")


if __name__ == "__main__":
    unittest.main()
