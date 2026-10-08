"""Structural inspector tests; none execute extension code or prove iOS support."""

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "inspect_vbook.py"
SPEC = importlib.util.spec_from_file_location("inspect_vbook", MODULE_PATH)
inspector = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = inspector
SPEC.loader.exec_module(inspector)


class InspectVBookTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def package(self, manifest=None, extra=(), scripts=None):
        manifest = manifest if manifest is not None else {
            "metadata": {"name": "Test", "type": "novel", "version": 1},
            "script": {"detail": "detail.js", "toc": "toc.js", "chap": "chap.js"},
        }
        scripts = scripts if scripts is not None else {
            "detail.js": "function execute(url) { return Response.success({name: 'Test'}); }",
            "toc.js": "function execute(url) { return Response.success([]); }",
            "chap.js": "load('shared.js'); load('crypto.js'); function execute(url) { return Response.success(fetch(url).html().select('p').html()); }",
            "shared.js": "var DOMAIN = 'https://example.invalid';",
        }
        path = self.root / "plugin.zip"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("plugin.json", json.dumps(manifest))
                for name, source in scripts.items():
                    archive.writestr("src/" + name, source)
                for name, contents in extra:
                    entry = zipfile.ZipInfo()
                    entry.filename = name  # Preserve malformed separators on Windows.
                    archive.writestr(entry, contents)
        return path

    def codes(self, result):
        return {item["code"] for item in result["findings"]}

    def test_valid_package_hash_and_heuristic_host_dependencies(self):
        path = self.package()
        result = inspector.inspect_file(path)
        self.assertEqual(result["status"], "inspected")
        self.assertEqual(result["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(result["runtime_compatibility"], "not_tested")
        self.assertFalse(result["archive"]["files_extracted"])
        chapter = next(item for item in result["script_scan"]["files"] if item["filename"] == "chap.js")
        self.assertEqual(chapter["host_api_names"], ["fetch", "Response", "load"])
        self.assertEqual(chapter["literal_load_dependencies"], [
            {"filename": "shared.js", "status": "package_file"},
            {"filename": "crypto.js", "status": "documented_builtin"},
        ])

    def test_required_mapping_missing(self):
        result = inspector.inspect_file(self.package({"metadata": {"type": "novel"},
                                                      "script": {"detail": "detail.js"}}))
        self.assertEqual(result["status"], "invalid")
        self.assertIn("missing_required_script", self.codes(result))

    def test_declared_file_missing(self):
        result = inspector.inspect_file(self.package(scripts={"detail.js": "", "toc.js": ""}))
        self.assertIn("missing_declared_script_file", self.codes(result))
        self.assertEqual(result["status"], "invalid")

    def test_missing_root_manifest(self):
        path = self.root / "missing.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("wrapper/plugin.json", "{}")
        result = inspector.inspect_file(path)
        self.assertEqual(result["status"], "invalid")
        self.assertIn("inspection_rejected", self.codes(result))

    def test_traversal_and_absolute_paths_rejected(self):
        for name in ("../outside.js", "src/../../outside.js", "/tmp/a.js", "C:/a.js", "src\\a.js"):
            with self.subTest(name=name):
                result = inspector.inspect_file(self.package(extra=[(name, "x")]))
                self.assertEqual(result["status"], "invalid")
                self.assertNotIn("manifest", result)

    def test_duplicate_and_case_colliding_paths_rejected(self):
        for name in ("plugin.json", "PLUGIN.JSON"):
            with self.subTest(name=name):
                result = inspector.inspect_file(self.package(extra=[(name, "{}")]))
                self.assertEqual(result["status"], "invalid")
                self.assertNotIn("manifest", result)

    def test_size_limits_checked_before_manifest_read(self):
        path = self.package(extra=[("unused.dat", "x" * 5000)])
        for limits in (inspector.Limits(max_entry_bytes=1000),
                       inspector.Limits(max_uncompressed_bytes=1000),
                       inspector.Limits(max_entries=2),
                       inspector.Limits(max_input_bytes=10),
                       inspector.Limits(max_manifest_bytes=10)):
            with self.subTest(limits=limits):
                result = inspector.inspect_file(path, limits)
                self.assertEqual(result["status"], "invalid")
                self.assertNotIn("manifest", result)

    def test_zip_symlink_rejected(self):
        path = self.package()
        with zipfile.ZipFile(path, "a") as archive:
            symlink = zipfile.ZipInfo("src/link.js")
            symlink.create_system = 3
            symlink.external_attr = 0o120777 << 16
            archive.writestr(symlink, "outside")
        self.assertEqual(inspector.inspect_file(path)["status"], "invalid")

    def test_invalid_json_manifest_rejected(self):
        path = self.root / "bad.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("plugin.json", "{bad")
        self.assertEqual(inspector.inspect_file(path)["status"], "invalid")

    def test_duplicate_json_key_rejected(self):
        path = self.root / "duplicate.json"
        path.write_text('{"data": [], "data": []}', encoding="utf-8")
        self.assertEqual(inspector.inspect_file(path)["status"], "invalid")

    def test_manifest_shape_rejected(self):
        for manifest in ({"metadata": [], "script": {}},
                         {"metadata": {}, "script": []},
                         {"metadata": {}, "script": {}, "config": []}):
            with self.subTest(manifest=manifest):
                self.assertEqual(inspector.inspect_file(self.package(manifest))["status"], "invalid")

    def test_encrypted_package_never_scans_ciphertext(self):
        manifest = {"metadata": {"type": "novel", "encrypt": True},
                    "script": {"detail": "detail.js", "toc": "toc.js", "chap": "chap.js"}}
        result = inspector.inspect_file(self.package(manifest, scripts={
            key: "fetch('would-be-executed'); function execute() {}"
            for key in ("detail.js", "toc.js", "chap.js")
        }))
        self.assertEqual(result["status"], "inspected")
        self.assertFalse(result["encryption"]["decryption_attempted"])
        for script in result["script_scan"]["files"]:
            self.assertEqual(script["scan_status"], "skipped_encrypted")
            self.assertNotIn("host_api_names", script)

    def test_legacy_type_and_config_included(self):
        manifest = {"metadata": {"type": "chinese_novel"},
                    "script": {"detail": "detail.js", "toc": "toc.js", "chap": "chap.js"},
                    "config": {"DOMAIN": {"mode": "input", "default": "https://example.invalid"}}}
        result = inspector.inspect_file(self.package(manifest))
        self.assertEqual(result["content_type"]["normalized"], "novel")
        self.assertEqual(result["manifest"]["config"], manifest["config"])
        self.assertIn("legacy_type", self.codes(result))

    def test_registry_local_only(self):
        path = self.root / "registry.json"
        path.write_text(json.dumps({"metadata": {"author": "Test"}, "data": [
            {"name": "Test", "path": "https://example.invalid/plugin.zip", "type": "novel"}]}))
        result = inspector.inspect_file(path)
        self.assertEqual(result["status"], "inspected")
        self.assertEqual(result["registry"]["item_count"], 1)
        self.assertFalse(result["registry"]["entries"][0]["package_downloaded"])
        self.assertNotIn("script_scan", result)
        self.assertEqual(inspector.inspect_file(path, inspector.Limits(max_registry_items=1))["status"], "inspected")

    def test_registry_bad_entries_reported(self):
        path = self.root / "registry.json"
        path.write_text(json.dumps({"data": ["bad", {"name": "Missing path"}]}))
        result = inspector.inspect_file(path)
        self.assertEqual(result["status"], "invalid")
        self.assertIn("invalid_registry_entry", self.codes(result))
        self.assertIn("missing_registry_package_path", self.codes(result))
        self.assertEqual(inspector.inspect_file(path, inspector.Limits(max_registry_items=1))["status"], "invalid")

    def test_standalone_manifest_does_not_open_adjacent_scripts(self):
        path = self.root / "manifest.json"
        path.write_text(json.dumps({"metadata": {"type": "novel"}, "script": {
            "detail": "detail.js", "toc": "toc.js", "chap": "chap.js"}}))
        result = inspector.inspect_file(path)
        self.assertEqual(result["status"], "inspected")
        self.assertEqual(result["kind"], "manifest")
        self.assertFalse(result["script_files_verified"])
        self.assertEqual(result["script_scan"]["files"], [])

    def test_cli_output_and_exit_code(self):
        output = self.root / "out" / "report.json"
        self.assertEqual(inspector.main([str(self.package()), "--output", str(output)]), 0)
        self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["status"], "inspected")
        self.assertEqual(inspector.main([str(self.root / "absent.zip"), "--output", str(output)]), 1)
        self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["status"], "invalid")

    def test_cli_refuses_to_overwrite_input(self):
        path = self.package()
        before = path.read_bytes()
        with self.assertRaises(SystemExit) as error:
            inspector.main([str(path), "--output", str(path)])
        self.assertEqual(error.exception.code, 2)
        self.assertEqual(path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
