"""Execute real short-lived child processes; no Xcode/device behavior implied."""
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import unittest
from unittest import mock

from run_build_phase import run_phase


class BuildPhaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tachi-build-phase-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.log = self.root / "phase.log"
        self.status = self.root / "phase.json"

    def run_code(self, code, **limits):
        return run_phase("fixture", [sys.executable, "-X", "utf8", "-u", "-c", code], self.log,
                         status=self.status, timeout=limits.pop("timeout", 10), **limits)

    def test_success_preserves_unicode_log_and_status_without_command_arguments(self):
        self.assertEqual(self.run_code("print('TachiBooks \\u0111\\u00e3 ki\\u1ec3m tra')"), 0)
        self.assertIn("đã kiểm tra", self.log.read_text(encoding="utf-8"))
        status = json.loads(self.status.read_text())
        self.assertEqual((status["result"], status["exitCode"]), ("passed", 0))
        self.assertNotIn("command", status)

    def test_failure_propagates_child_exit_and_keeps_error_output(self):
        self.assertEqual(self.run_code("import sys; print('compile error'); sys.exit(65)"), 65)
        self.assertIn("compile error", self.log.read_text())
        self.assertEqual(json.loads(self.status.read_text())["result"], "command_failed")

    def test_silent_child_is_stopped_by_idle_limit(self):
        started = time.monotonic()
        self.assertEqual(self.run_code("import time; time.sleep(30)", idle_timeout=0.6), 124)
        self.assertLess(time.monotonic() - started, 8)
        self.assertEqual(json.loads(self.status.read_text())["result"], "idle_timeout")

    def test_busy_child_still_has_wall_limit(self):
        self.assertEqual(self.run_code(
            "import time\nwhile True:\n print('working', flush=True); time.sleep(.05)",
            timeout=0.8, idle_timeout=0.6), 124)
        self.assertEqual(json.loads(self.status.read_text())["result"], "wall_timeout")

    def test_silent_success_does_not_require_compiler_output(self):
        self.assertEqual(self.run_code("import time; time.sleep(.1)"), 0)

    def test_missing_executable_fails_without_exposing_argument(self):
        code = run_phase("missing", [str(self.root / "not-a-command"), "SECRET_ARGUMENT"],
                         self.log, timeout=2, status=self.status)
        self.assertEqual(code, 127)
        self.assertNotIn("SECRET_ARGUMENT", self.status.read_text() + self.log.read_text())

    def test_interrupted_library_call_restores_signal_handler_and_records_failure(self):
        previous = signal.getsignal(signal.SIGTERM)
        with mock.patch("run_build_phase.subprocess.Popen", side_effect=KeyboardInterrupt):
            self.assertEqual(self.run_code("print('not started')"), 130)
        self.assertEqual(signal.getsignal(signal.SIGTERM), previous)
        self.assertEqual(json.loads(self.status.read_text())["result"], "interrupted")

    @unittest.skipUnless(os.name == "posix", "Process-group cleanup needs POSIX/macOS")
    def test_timeout_also_stops_descendant_with_inherited_stdout(self):
        marker = self.root / "leaked-child"
        child = f"import pathlib,time; time.sleep(4); pathlib.Path({str(marker)!r}).touch()"
        code = f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{child!r}]); time.sleep(30)"
        self.assertEqual(self.run_code(code, timeout=0.6), 124)
        time.sleep(4.2)
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
