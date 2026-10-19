"""Test simulator selection and native-check command plans without claiming iOS execution."""
import contextlib
import io
import json
import os
import re
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

from check_ios_native_sources import commands, flutter_framework


ROOT = Path(__file__).resolve().parents[1]


class CocoaPodsSetupTests(unittest.TestCase):
    def test_cocoapods_project_has_no_dangling_generated_swift_package(self):
        project = (ROOT / 'ios/Runner.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        self.assertNotIn('FlutterGeneratedPluginSwiftPackage', project)
        declared = set(re.findall(r'^\s*([A-F0-9]{24})\s*(?:/\*.*?\*/\s*)?=', project, re.M))
        used = set(re.findall(r'\b[A-F0-9]{24}\b', project))
        self.assertEqual(used - declared, set())
        scheme = ET.parse(ROOT / 'ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme')
        self.assertIsNotNone(scheme.find('TestAction/Testables/TestableReference'))
        self.assertIsNone(scheme.find('BuildAction/PreActions'))

    def test_system_continued_task_registration_keeps_the_original_app_target(self):
        import plistlib
        project = (ROOT / 'ios/Runner.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        info = plistlib.loads((ROOT / 'ios/Runner/Info.plist').read_bytes())
        permitted = info['BGTaskSchedulerPermittedIdentifiers']
        self.assertIn('dev.tachibooks.tachiBooks.work.continued.*', permitted)
        self.assertIn('dev.tachibooks.tachiBooks.downloads.continued', permitted)
        self.assertIn('dev.tachibooks.downloads.processing', permitted)
        self.assertIn('processing', info['UIBackgroundModes'])
        self.assertNotIn('TaskActivityWidget', project)
        for name in ['TaskContinuedWork.swift', 'TaskContinuedWorkTests.swift']:
            self.assertRegex(project, re.escape(name) + r' in Sources \*/ = \{isa = PBXBuildFile;')
            self.assertRegex(project, re.escape(name) + r' in Sources \*/,')

    def test_workflow_integrates_dependencies_before_issuing_reusable_preflight_receipt(self):
        workflow = (ROOT / '.github/workflows/ios-build.yml').read_text(encoding='utf-8')
        steps = re.findall(r'^      - name: [^\n]+\n(.*?)(?=^      - name:|\Z)',
                           workflow, re.M | re.S)
        def index(command):
            return next(i for i, step in enumerate(steps) if command in step)
        quick = index('ios_build_preflight.py --quick')
        engine = index('-- python3 tools/configure_ios_tachi_runtime.py')
        objc = index('-- python3 tools/check_ios_native_sources.py --objc-only')
        dependencies = index('run: bash tools/prepare_ios_dependencies.sh')
        full = index('run: python3 tools/ios_build_preflight.py --receipt')
        native = index('run: bash tools/test_ios_native_tabs.sh')
        release = index('run: bash tools/build_ios.sh')
        self.assertEqual([quick, engine, objc, dependencies, full, native, release],
                         sorted([quick, engine, objc, dependencies, full, native, release]))
        self.assertNotIn('if:', steps[dependencies], 'Device-only builds also need dependency integration')
        self.assertNotIn('if:', steps[full])

    def test_standalone_builds_prepare_dependencies_before_full_receipt(self):
        for name in ('tools/test_ios_native_tabs.sh', 'tools/build_ios.sh'):
            with self.subTest(script=name):
                script = (ROOT / name).read_text(encoding='utf-8')
                branch = script.split('if [[ -n "${TACHI_PREFLIGHT_RECEIPT:-}" ]]; then', 1)[1]
                ci, standalone = branch.split('\nelse\n', 1)
                standalone = standalone.split('\nfi\n', 1)[0]
                self.assertIn('ios_build_preflight.py --verify', ci)
                self.assertNotIn('prepare_ios_dependencies.sh', ci)
                quick = standalone.index('ios_build_preflight.py --quick')
                preparation = standalone.index('bash tools/prepare_ios_dependencies.sh')
                full = standalone.index('ios_build_preflight.py --receipt')
                self.assertLess(quick, preparation)
                self.assertLess(preparation, full)

    def test_dependency_preparation_is_bounded_and_checks_installed_lock(self):
        script = (ROOT / 'tools/prepare_ios_dependencies.sh').read_text(encoding='utf-8')
        self.assertIn('--name native-pods-install --timeout 600', script)
        self.assertIn('--name native-pods-configuration --timeout 240', script)
        self.assertIn('-- pod install --project-directory=ios --verbose', script)
        self.assertIn('-- flutter build ios --simulator --debug --no-pub --config-only', script)
        # Execute the actual postcondition against mismatched and matching
        # fixture lockfiles; no CocoaPods/Xcode execution is claimed here.
        code = script.split("python3 - <<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        with tempfile.TemporaryDirectory(prefix='tachi-pods-lock-') as temporary:
            root = Path(temporary)
            (root / 'ios/Pods').mkdir(parents=True)
            previous = Path.cwd()
            try:
                os.chdir(root)
                with self.assertRaisesRegex(SystemExit, 'setup is incomplete'):
                    exec(compile(code, 'prepare_ios_dependencies.sh:postcondition', 'exec'), {})
                (root / 'ios/Podfile.lock').write_text('resolved dependencies')
                (root / 'ios/Pods/Manifest.lock').write_text('different dependencies')
                with self.assertRaisesRegex(SystemExit, 'setup is incomplete'):
                    exec(compile(code, 'prepare_ios_dependencies.sh:postcondition', 'exec'), {})
                (root / 'ios/Pods/Manifest.lock').write_text('resolved dependencies')
                with contextlib.redirect_stdout(io.StringIO()):
                    exec(compile(code, 'prepare_ios_dependencies.sh:postcondition', 'exec'), {})
            finally:
                os.chdir(previous)


class NativeBuildPlanTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tachi-native-plan-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.flutter = self.root / "flutter"
        for name in (
            "ios/Runner/AppDelegate.swift", "ios/Runner/Runner-Bridging-Header.h",
            "ios/Runner/GeneratedPluginRegistrant.h", "ios/RunnerTests/RunnerTests.swift",
            "packages/vbook_runtime/ios/Classes/VbookRuntimePlugin.swift",
            "packages/tachi_runtime/ios/Classes/TachiImageCodec.m",
            "packages/tachi_runtime/ios/Runtime/include/jni.h",
            "packages/tachi_runtime/ios/Runtime/include/darwin/jni_md.h",
        ):
            self.touch(self.root / name)
        for variant in ("ios-arm64", "ios-arm64_x86_64-simulator"):
            self.touch(self.flutter / "bin/cache/artifacts/engine/ios/Flutter.xcframework" /
                       variant / "Flutter.framework/Headers/Flutter.h")
        self.sdks = {"iphoneos": self.root / "device.sdk", "iphonesimulator": self.root / "simulator.sdk"}

    def touch(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture; not SDK code")

    def test_runner_checks_use_real_selected_framework_and_sdk_for_each_target(self):
        plan = dict(commands(self.root, self.flutter, self.sdks, swift=True, objc=False))
        self.assertEqual(len(plan), 3)
        for sdk, target in (("iphoneos", "arm64-apple-ios15.0"),
                            ("iphonesimulator", "arm64-apple-ios15.0-simulator")):
            command = plan["swift-runner-" + sdk]
            self.assertEqual(command[command.index("-target") + 1], target)
            self.assertEqual(command[command.index("-sdk") + 1], str(self.sdks[sdk]))
            self.assertIn("-typecheck", command)
            self.assertEqual(command[command.index("-F") + 1],
                             str(flutter_framework(self.flutter, sdk == "iphonesimulator").parent))
        self.assertIn("-parse", plan["swift-test-plugin-parse"])

    def test_jni_headers_are_required_before_objc_compile_checks(self):
        plan = dict(commands(self.root, self.flutter, self.sdks, swift=False, objc=True))
        self.assertEqual(len(plan), 2)
        for command in plan.values():
            self.assertIn("-fsyntax-only", command)
            self.assertTrue(command[-1].endswith("TachiImageCodec.m"))
        (self.root / "packages/tachi_runtime/ios/Runtime/include/darwin/jni_md.h").unlink()
        with self.assertRaisesRegex(ValueError, "Verified JNI headers"):
            commands(self.root, self.flutter, self.sdks, swift=False, objc=True)

    def test_missing_real_framework_never_silently_skips_native_check(self):
        for framework in self.flutter.rglob("Flutter.h"):
            framework.unlink()
        with self.assertRaisesRegex(ValueError, "Missing real Flutter framework"):
            commands(self.root, self.flutter, self.sdks, swift=True, objc=False)

    def test_continued_work_is_checked_on_both_targets_without_increasing_minimum_ios(self):
        path = self.root / 'ios/Runner/TaskContinuedWork.swift'
        self.touch(path)
        plan = dict(commands(self.root, self.flutter, self.sdks, swift=True, objc=False))
        for sdk in ('iphoneos', 'iphonesimulator'):
            command = plan['swift-runner-' + sdk]
            self.assertIn(str(path), command)
            self.assertIn('arm64-apple-ios15.0' + ('-simulator' if sdk == 'iphonesimulator' else ''), command)


class NativeSimulatorResourcePlanTests(unittest.TestCase):
    def setUp(self):
        self.script = (ROOT / 'tools/test_ios_native_tabs.sh').read_text(encoding='utf-8')
        programs = self.script.split('python3 - "$tachi_simulator" "$tachi_root/artifacts/native-tabs-boot-ownership.json" <<\'PY\'\n')
        self.boot = programs[1].split('\nPY\n', 1)[0]
        self.cleanup = programs[2].split('\nPY\n', 1)[0]
        temporary = tempfile.TemporaryDirectory(prefix='tachi-simulator-ownership-')
        self.addCleanup(temporary.cleanup)
        self.ownership = Path(temporary.name) / 'ownership.json'

    def test_simulator_starts_after_compile_and_before_hosted_tests(self):
        compile_position = self.script.index('-- xcodebuild build-for-testing')
        boot_position = self.script.index('python3 - "$tachi_simulator" "$tachi_root/artifacts/native-tabs-boot-ownership.json" <<\'PY\'')
        test_position = self.script.index('-- xcodebuild test-without-building')
        self.assertLess(compile_position, boot_position)
        self.assertLess(boot_position, test_position)
        self.assertIn('COMPILER_INDEX_STORE_ENABLE=NO', self.script)
        self.assertIn('-showBuildTimingSummary', self.script)
        self.assertIn('--timeout 1500 --idle-timeout 300', self.script)
        self.assertIn('--name native-simulator-tests --timeout 300', self.script)

    def run_boot(self, state, side_effect=None):
        inventory = {'devices': {'ios27': [{'udid': '15PM', 'state': state}]}}
        with mock.patch('subprocess.check_output', return_value=json.dumps(inventory)), \
                mock.patch('subprocess.run', side_effect=side_effect) as run, \
                mock.patch.object(sys, 'argv', ['boot', '15PM', str(self.ownership)]):
            exec(compile(self.boot, 'test_ios_native_tabs.sh:boot', 'exec'), {})
        return run

    def test_shutdown_selected_device_boots_and_waits_with_existing_limits(self):
        run = self.run_boot('Shutdown')
        self.assertEqual(run.call_args_list, [
            mock.call(['xcrun', 'simctl', 'boot', '15PM'], check=True, timeout=60),
            mock.call(['xcrun', 'simctl', 'bootstatus', '15PM', '-b'], check=True, timeout=180),
        ])

    def test_booted_device_is_not_booted_a_second_time(self):
        run = self.run_boot('Booted')
        run.assert_called_once_with(['xcrun', 'simctl', 'bootstatus', '15PM', '-b'], check=True, timeout=180)

    def run_cleanup(self, started, udid='15PM', state='Booted'):
        self.ownership.write_text(json.dumps({'udid': udid, 'startedByInvocation': started}))
        inventory = {'devices': {'ios27': [{'udid': '15PM', 'state': state}]}}
        with mock.patch('subprocess.check_output', return_value=json.dumps(inventory)), \
                mock.patch('subprocess.run') as run, \
                mock.patch.object(sys, 'argv', ['cleanup', '15PM', str(self.ownership)]), \
                contextlib.redirect_stdout(io.StringIO()):
            exec(compile(self.cleanup, 'test_ios_native_tabs.sh:cleanup', 'exec'), {})
        return run

    def test_cleanup_only_stops_the_simulator_started_by_this_invocation(self):
        self.run_cleanup(True).assert_called_once_with(['xcrun', 'simctl', 'shutdown', '15PM'], check=True, timeout=60)
        self.run_cleanup(False).assert_not_called()
        self.run_cleanup(True, state='Shutdown').assert_not_called()

    def test_cleanup_rejects_mismatched_device_ownership(self):
        with self.assertRaisesRegex(SystemExit, 'ownership does not match'):
            self.run_cleanup(True, udid='OTHER')

    def test_cleanup_runs_after_the_screenshot_and_before_release(self):
        self.assertLess(self.script.index("'screenshot'"), self.script.index('ownership = json.loads'))
        release = (ROOT / 'tools/build_ios.sh').read_text(encoding='utf-8')
        self.assertIn('--release --no-codesign --no-pub --verbose', release)
        self.assertIn('--name device-release --timeout 1200', release)

    def test_boot_timeout_aborts_before_hosted_tests(self):
        import subprocess
        with self.assertRaisesRegex(SystemExit, 'bounded timeout'):
            self.run_boot('Shutdown', subprocess.TimeoutExpired(['xcrun', 'simctl', 'boot', '15PM'], 60))


class SimulatorSelectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tachi-simulator-plan-")
        self.addCleanup(temporary.cleanup)
        self.report = Path(temporary.name) / "simulator.json"
        script = (ROOT / "tools/test_ios_native_tabs.sh").read_text(encoding="utf-8")
        selection = script.split('tachi_simulator="$(python3 - ', 1)[1]
        self.code = selection.split("<<'PY'\n", 1)[1].split('\nPY\n)"', 1)[0]
        self.runtime_id = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        self.inventory = {
            "runtimes": [{"identifier": self.runtime_id, "name": "iOS 27.0",
                          "isAvailable": True, "version": "27.0",
                          "supportedDeviceTypes": [{"identifier": "15pm"}]}],
            "devicetypes": [{"identifier": "15pm", "name": "iPhone 15 Pro Max"},
                            {"identifier": "air", "name": "iPhone Air"}],
            "devices": {self.runtime_id: []},
        }

    def select(self, create=None):
        responses = [json.dumps(self.inventory), "27.0"]
        if create:
            responses.append(create)
        with mock.patch("subprocess.check_output", side_effect=responses) as call, \
                mock.patch.object(sys, "argv", ["selector", str(self.report)]), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            exec(compile(self.code, "test_ios_native_tabs.sh:selector", "exec"), {})
        return json.loads(self.report.read_text()), call

    def test_selects_existing_15_pro_max_instead_of_booted_air(self):
        self.inventory["devices"][self.runtime_id] = [
            {"deviceTypeIdentifier": "air", "isAvailable": True, "udid": "AIR",
             "name": "iPhone Air", "state": "Booted"},
            {"deviceTypeIdentifier": "15pm", "isAvailable": True, "udid": "15PM",
             "name": "iPhone 15 Pro Max", "state": "Shutdown"},
        ]
        report, call = self.select()
        self.assertEqual(report["device"]["udid"], "15PM")
        self.assertEqual(call.call_count, 2)

    def test_creates_15_pro_max_only_when_runtime_supports_it(self):
        report, call = self.select("CREATED-15PM")
        self.assertEqual(report["device"]["udid"], "CREATED-15PM")
        self.assertEqual(call.call_args.args[0], [
            "xcrun", "simctl", "create", "iPhone 15 Pro Max", "15pm", self.runtime_id])
        self.assertEqual(call.call_args.kwargs["timeout"], 60)

    def test_missing_15_pro_max_is_an_error_before_any_compilation(self):
        self.inventory["runtimes"][0]["supportedDeviceTypes"] = [{"identifier": "air"}]
        with self.assertRaisesRegex(SystemExit, "No fallback to iPhone Air"):
            self.select()
        self.assertFalse(self.report.exists())


if __name__ == "__main__":
    unittest.main()
