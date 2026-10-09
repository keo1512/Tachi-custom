"""Offline config-helper regression checks; no Firebase account is contacted."""

import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("configure_firebase_ios", Path(__file__).with_name("configure_firebase_ios.py"))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class FirebaseIosConfigTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.ios = self.root / "ios"
        (self.ios / "Runner").mkdir(parents=True)
        (self.ios / "Runner.xcodeproj").mkdir()
        source = Path(__file__).resolve().parent.parent / "ios"
        self.info = self.ios / "Runner" / "Info.plist"
        self.project = self.ios / "Runner.xcodeproj" / "project.pbxproj"
        self.info.write_bytes((source / "Runner" / "Info.plist").read_bytes())
        self.project.write_bytes((source / "Runner.xcodeproj" / "project.pbxproj").read_bytes())
        self.config = self.root / "fixture.plist"
        self.write_config()

    def write_config(self, bundle=helper.BUNDLE_ID):
        # Synthetic identifiers only; this is not a working Firebase project.
        self.config.write_bytes(plistlib.dumps({
            "BUNDLE_ID": bundle, "GOOGLE_APP_ID": "1:000:ios:test", "PROJECT_ID": "fixture-only",
            "API_KEY": "fixture-only", "CLIENT_ID": "000-test.apps.googleusercontent.com",
            "REVERSED_CLIENT_ID": "com.googleusercontent.apps.000-test",
        }))

    def test_matching_config_preserves_input_and_existing_schemes_and_is_idempotent(self):
        info = plistlib.loads(self.info.read_bytes())
        info["CFBundleURLTypes"] = [{"CFBundleURLSchemes": ["tachibooks-existing"]}]
        self.info.write_bytes(plistlib.dumps(info))
        before = self.config.read_bytes()
        helper.configure(self.config, self.ios)
        helper.configure(self.config, self.ios)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual((self.ios / "Runner" / helper.CONFIG_NAME).read_bytes(), before)
        info = plistlib.loads(self.info.read_bytes())
        schemes = [scheme for item in info["CFBundleURLTypes"] for scheme in item["CFBundleURLSchemes"]]
        self.assertEqual(schemes, ["tachibooks-existing", "com.googleusercontent.apps.000-test"])
        project = self.project.read_text(encoding="utf-8")
        self.assertEqual(project.count(f"{helper.RESOURCE_ID} /* {helper.CONFIG_NAME} in Resources */ ="), 1)
        self.assertEqual(project.count(f"{helper.REFERENCE_ID} /* {helper.CONFIG_NAME} */ ="), 1)

    def test_moneytracker_bundle_is_rejected_before_any_destination_mutation(self):
        self.write_config("com.example.moneyTracker")
        info, project = self.info.read_bytes(), self.project.read_bytes()
        with self.assertRaises(ValueError):
            helper.configure(self.config, self.ios)
        self.assertEqual(self.info.read_bytes(), info)
        self.assertEqual(self.project.read_bytes(), project)
        self.assertFalse((self.ios / "Runner" / helper.CONFIG_NAME).exists())

    def test_inconsistent_callback_is_rejected_before_any_destination_mutation(self):
        config = plistlib.loads(self.config.read_bytes())
        config["REVERSED_CLIENT_ID"] = "com.googleusercontent.apps.wrong"
        self.config.write_bytes(plistlib.dumps(config))
        before = self.project.read_bytes()
        with self.assertRaises(ValueError):
            helper.configure(self.config, self.ios)
        self.assertEqual(self.project.read_bytes(), before)
        self.assertFalse((self.ios / "Runner" / helper.CONFIG_NAME).exists())

    def test_malformed_existing_url_schemes_are_rejected_before_any_mutation(self):
        info = plistlib.loads(self.info.read_bytes())
        info["CFBundleURLTypes"] = [{"CFBundleURLSchemes": "existing-not-a-list"}]
        self.info.write_bytes(plistlib.dumps(info))
        before = self.info.read_bytes(), self.project.read_bytes()
        with self.assertRaises(ValueError):
            helper.configure(self.config, self.ios)
        self.assertEqual((self.info.read_bytes(), self.project.read_bytes()), before)
        self.assertFalse((self.ios / "Runner" / helper.CONFIG_NAME).exists())

    def test_partial_existing_resource_reference_cannot_skip_runner_link_validation(self):
        helper.configure(self.config, self.ios)
        project = self.project.read_text(encoding="utf-8")
        project = project.replace(f"\n\t\t\t\t{helper.RESOURCE_ID} /* {helper.CONFIG_NAME} in Resources */,", "")
        self.project.write_text(project, encoding="utf-8")
        before = self.info.read_bytes(), self.project.read_bytes()
        with self.assertRaises(ValueError):
            helper.configure(self.config, self.ios)
        self.assertEqual((self.info.read_bytes(), self.project.read_bytes()), before)


if __name__ == "__main__":
    unittest.main()
