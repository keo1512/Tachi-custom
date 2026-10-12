import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("coverage_runner", HERE / "run.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class CoverageRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.case = {
            "case": "original-komga", "packageName": "eu.kanade.tachiyomi.extension.all.komga",
            "versionName": "1.4.47", "api": "1.4", "bytes": 100,
            "sha256": "a" * 64, "sourceIds": ["4508733312114627536"],
            "url": "https://github.com/keiyoushi/extensions/releases/download/pinned/tachiyomi-all.komga-v1.4.47.apk",
        }

    def matrix(self, cases):
        path = self.root / "matrix.json"
        path.write_text(json.dumps({"version": 1, "cases": cases}), encoding="utf-8")
        return path

    def operations(self):
        extension = {"id": self.case["packageName"], "installed": True,
                     "version": self.case["versionName"], "apkSha256": self.case["sha256"],
                     "sourceIds": self.case["sourceIds"]}
        identity = self.case["sourceIds"][0]
        return [
            {"method": "initialize", "args": {}, "response": {"ok": True, "result": {}}},
            {"method": "install", "args": {}, "response": {"ok": True, "result": extension}},
            {"method": "extensions", "args": {}, "response": {"ok": True, "result": [extension]}},
            {"method": "sources", "args": {}, "response": {"ok": True, "result": [{"id": identity}]}},
            {"method": "preferences", "args": {"sourceId": identity},
             "response": {"ok": True, "result": [{"key": "server_url", "type": "EditTextPreference"}]}},
        ]

    def test_accepts_decimal_64_bit_identity_without_rounding(self):
        actual = RUNNER.load_matrix(self.matrix([self.case]))
        self.assertEqual(actual["cases"][0]["sourceIds"], ["4508733312114627536"])

    def test_rejects_numeric_or_out_of_range_source_id(self):
        for identity in [4508733312114627536, str(2**63)]:
            case = dict(self.case, sourceIds=[identity])
            with self.subTest(identity=identity), self.assertRaises(ValueError):
                RUNNER.load_matrix(self.matrix([case]))

    def test_refuses_unbounded_catalogue_download(self):
        cases = [dict(self.case, case=f"case-{i}") for i in range(9)]
        with self.assertRaises(ValueError):
            RUNNER.load_matrix(self.matrix(cases))

    def test_refuses_duplicate_case_or_source_id(self):
        for cases in [[self.case, self.case], [dict(self.case, sourceIds=self.case["sourceIds"] * 2)]]:
            with self.subTest(cases=cases), self.assertRaises(ValueError):
                RUNNER.load_matrix(self.matrix(cases))

    def test_refuses_unpinned_url(self):
        with self.assertRaises(ValueError):
            RUNNER.load_matrix(self.matrix([dict(self.case, url="https://example.com/package.apk")]))

    def test_requires_original_apk_manifest_dex_and_exact_hash(self):
        path = self.root / "fixture.apk"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"binary-manifest")
            archive.writestr("classes.dex", b"original-dex")
        case = dict(self.case, bytes=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        RUNNER.verify_apk(path, case)
        with self.assertRaises(ValueError):
            RUNNER.verify_apk(path, dict(case, sha256="b" * 64))
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("dev/Example.class", b"jar-not-apk")
        case.update(bytes=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        with self.assertRaises(ValueError):
            RUNNER.verify_apk(path, case)

    def test_missing_cache_requires_explicit_bounded_fetch(self):
        with self.assertRaisesRegex(ValueError, "--fetch"):
            RUNNER.obtain_apk(self.case, self.root / "cache", False)

    def test_transport_ignores_original_extension_logs_but_requires_all_calls(self):
        requests = [{"method": "initialize", "args": {}}]
        line = RUNNER.PREFIX + '{"ok":true,"result":{}}'
        actual = RUNNER.parse_responses("Extension original log\n" + line + "\n", requests)
        self.assertEqual(actual[0]["response"]["ok"], True)
        with self.assertRaisesRegex(ValueError, "incomplete"):
            RUNNER.parse_responses("Extension original log\n", requests)

    def test_console_background_failures_are_not_hidden_by_successful_rpc(self):
        rpc = RUNNER.PREFIX + '{"ok":true,"result":{}}'
        for failure in [
            "java.lang.VerifyError: Bad type on operand stack",
            "java.lang.NoClassDefFoundError: android/widget/Missing",
            "java.lang.RuntimeException: Stub!",
            "java.lang.UnsatisfiedLinkError: no zstd in java.library.path",
            'Exception in thread "worker" java.lang.NullPointerException',
            "Missing MetadataExtensions SPI service",
            "TACHI_UNCAUGHT\tworker\tjava.io.IOException",
        ]:
            with self.subTest(failure=failure):
                self.assertEqual(RUNNER.runtime_diagnostics(rpc, failure), [failure])

    def test_console_normal_log_and_rpc_error_are_separate_evidence(self):
        rpc = RUNNER.PREFIX + '{"ok":false,"error":{"type":"VerifyError"}}'
        self.assertEqual(RUNNER.runtime_diagnostics(rpc + "\n[INFO] Factory loaded", "SLF4J: defaulting to NOP logger"), [])

    def test_directory_classpath_fingerprint_changes_with_real_compiled_bytes(self):
        classes = self.root / "host-classes"
        classes.mkdir()
        (classes / "Host.class").write_bytes(b"original-compiled-host")
        old = RUNNER.classpath_fingerprint(classes)
        (classes / "Host.class").write_bytes(b"changed-compiled-host")
        self.assertNotEqual(old, RUNNER.classpath_fingerprint(classes))

    def test_snapshot_holds_compiled_input_bytes_without_overwriting_source(self):
        source = self.root / "original.jar"
        source.write_bytes(b"immutable-host-jar")
        copied = RUNNER.snapshot_classpath([source], self.root / "snapshot")
        self.assertEqual(copied[0].read_bytes(), b"immutable-host-jar")
        source.write_bytes(b"new-build-arrives")
        self.assertEqual(copied[0].read_bytes(), b"immutable-host-jar")

    def test_unrelated_package_or_changed_persisted_ids_is_failure(self):
        for mutate in [
            lambda operations: operations[2]["response"]["result"].append({"id": "unexpected", "installed": True}),
            lambda operations: operations[2]["response"]["result"][0].update(sourceIds=["123"]),
        ]:
            operations = copy.deepcopy(self.operations())
            mutate(operations)
            with self.subTest(mutate=mutate):
                self.assertFalse(RUNNER.evaluate_phase(self.case, operations, True)["passed"])

    def test_success_checks_all_original_ids_and_version(self):
        actual = RUNNER.evaluate_phase(self.case, self.operations(), True)
        self.assertTrue(actual["passed"])
        self.assertEqual(actual["sourceCount"], 1)
        self.assertEqual(actual["preferenceCounts"], {"4508733312114627536": 1})

    def test_restart_dropped_factory_or_failed_preference_is_reported(self):
        operations = self.operations()[1:]
        operations[2]["response"]["result"] = []
        operations[3]["response"] = {"ok": False, "error": {"type": "NoSuchMethodError"}}
        actual = RUNNER.evaluate_phase(self.case, operations, False)
        self.assertFalse(actual["passed"])
        self.assertEqual({item["method"] for item in actual["failures"]}, {"sources", "preferences"})

    def test_installed_false_wrong_digest_and_integer_source_are_not_accepted(self):
        for mutate in [
            lambda operations: operations[2]["response"]["result"][0].update(installed=False),
            lambda operations: operations[2]["response"]["result"][0].update(apkSha256="b" * 64),
            lambda operations: operations[3]["response"]["result"][0].update(id=4508733312114627536),
        ]:
            operations = copy.deepcopy(self.operations())
            mutate(operations)
            with self.subTest(mutate=mutate):
                self.assertFalse(RUNNER.evaluate_phase(self.case, operations, True)["passed"])


if __name__ == "__main__":
    unittest.main()
