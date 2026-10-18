"""Preflight receipts must never reuse checks for changed or failed inputs."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import ios_build_preflight as preflight


class PreflightTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tachi-preflight-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True, capture_output=True)
        for name, data in {
            ".gitignore": "artifacts/\nios/Runner/GoogleService-Info.plist\n",
            "pubspec.lock": "fixture-lock",
            "lib/main.dart": "fixture source",
            "ios/Runner/AppDelegate.swift": "fixture native source",
            "tools/build_ios.sh": "fixture tool",
        }.items():
            self.write(name, data)
        subprocess.run(["git", "add", "."], cwd=self.root, check=True, capture_output=True)
        self.receipt = self.root / "artifacts/ios-preflight.json"
        self.receipt.parent.mkdir()

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data, encoding="utf-8")

    def valid_receipt(self):
        value = {
            "schema": 1, "sourceSha256": preflight.source_digest(self.root),
            "flutterVersion": preflight.FLUTTER_VERSION,
            "flutterRevision": preflight.FLUTTER_REVISION,
            "checks": list(preflight.CHECKS), "nativeRuntimeVerified": False,
        }
        self.receipt.write_text(json.dumps(value))
        return value

    def test_identical_source_reuses_receipt_and_generated_output_does_not_change_it(self):
        self.valid_receipt()
        self.write("artifacts/any.log", "generated output")
        preflight.verify_receipt(self.root, self.receipt)

    def test_dart_native_build_config_and_new_sources_invalidate_receipt(self):
        for name in ("lib/main.dart", "ios/Runner/AppDelegate.swift", "tools/build_ios.sh",
                     "pubspec.lock", "test/new_test.dart", ".github/workflows/ios-build.yml"):
            with self.subTest(name=name):
                self.valid_receipt()
                self.write(name, "changed source")
                with self.assertRaisesRegex(ValueError, "source/config changed"):
                    preflight.verify_receipt(self.root, self.receipt)

    def test_deleted_native_source_and_changed_private_config_invalidate_receipt(self):
        self.valid_receipt()
        (self.root / "ios/Runner/AppDelegate.swift").unlink()
        with self.assertRaises(ValueError):
            preflight.verify_receipt(self.root, self.receipt)
        self.write("ios/Runner/GoogleService-Info.plist", "private fixture")
        self.valid_receipt()
        self.write("ios/Runner/GoogleService-Info.plist", "changed private fixture")
        with self.assertRaises(ValueError):
            preflight.verify_receipt(self.root, self.receipt)
        self.assertNotIn("private fixture", self.receipt.read_text())

    def test_generated_pod_lock_is_allowed_but_a_tracked_lock_is_checked(self):
        self.valid_receipt()
        self.write("ios/Podfile.lock", "first CocoaPods resolution")
        preflight.verify_receipt(self.root, self.receipt)
        subprocess.run(["git", "add", "ios/Podfile.lock"], cwd=self.root, check=True, capture_output=True)
        self.valid_receipt()
        self.write("ios/Podfile.lock", "different resolution")
        with self.assertRaises(ValueError):
            preflight.verify_receipt(self.root, self.receipt)

    def test_missing_check_and_wrong_toolchain_are_rejected(self):
        for field, value in (("checks", ["flutter-tests"]), ("flutterRevision", "wrong")):
            receipt = self.valid_receipt()
            receipt[field] = value
            self.receipt.write_text(json.dumps(receipt))
            with self.assertRaises(ValueError):
                preflight.verify_receipt(self.root, self.receipt)

    def run_main(self, phase_code, digests=None):
        version = json.dumps({"frameworkVersion": preflight.FLUTTER_VERSION,
                              "frameworkRevision": preflight.FLUTTER_REVISION})
        with mock.patch.object(preflight, "ROOT", self.root), \
                mock.patch.object(sys, "argv", ["preflight", "--receipt", str(self.receipt)]), \
                mock.patch.object(sys, "platform", "darwin"), \
                mock.patch.object(preflight, "source_digest", side_effect=digests or ["same", "same"]), \
                mock.patch.object(preflight.subprocess, "check_output", return_value=version), \
                mock.patch.object(preflight, "run_phase", return_value=phase_code) as phase:
            result = preflight.main()
        return result, phase

    def test_first_failed_check_stops_remaining_work_and_removes_old_success(self):
        self.valid_receipt()
        code, phase = self.run_main(65)
        self.assertEqual(code, 65)
        self.assertEqual(phase.call_count, 1)
        self.assertFalse(self.receipt.exists())

    def test_change_during_checks_cannot_publish_success(self):
        self.valid_receipt()
        with self.assertRaisesRegex(ValueError, "changed during preflight"):
            self.run_main(0, ["before", "after"])
        self.assertFalse(self.receipt.exists())


if __name__ == "__main__":
    unittest.main()
