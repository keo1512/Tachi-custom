"""Execute real short-lived child processes; no Xcode/device behavior implied."""
import json
import io
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from run_build_phase import run_phase, _stop, _stop_child, _CleanupResult


def subprocess_timeout():
    return subprocess.TimeoutExpired("owned fixture", .1)


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

    def test_completed_success_and_failure_never_signal_reaped_group(self):
        with mock.patch("run_build_phase._stop", side_effect=AssertionError("unexpected signal")):
            self.assertEqual(self.run_code("print('done')"), 0)
            self.assertEqual(self.run_code("import sys; sys.exit(65)"), 65)

    def test_denied_group_signal_falls_back_to_owned_child(self):
        process = mock.Mock(pid=123)
        process.poll.return_value = None
        with mock.patch("run_build_phase.os.name", "posix"), \
                mock.patch("run_build_phase.os.killpg", side_effect=PermissionError, create=True), \
                mock.patch("run_build_phase.signal.SIGKILL", 9, create=True):
            cleanup = _stop(process)
        self.assertFalse(cleanup.verified)
        self.assertEqual(len(cleanup.warnings), 2)
        process.terminate.assert_called_once()
        process.wait.assert_called_once_with(timeout=2)

    def test_group_signal_races_and_denials_never_probe_with_signal_zero(self):
        scenarios = (
            ("group already gone", [ProcessLookupError], True),
            ("term accepted kill raced exit", [None, ProcessLookupError], True),
            ("term denied kill accepted", [PermissionError, None], True),
            ("term accepted kill denied", [None, PermissionError], False),
            ("both denied", [PermissionError, PermissionError], False),
            ("other group OS failure", [OSError, OSError], False),
        )
        for label, signals, expected in scenarios:
            with self.subTest(label=label):
                process = mock.Mock(pid=123)
                process.poll.return_value = 0
                process.wait.return_value = 0
                with mock.patch("run_build_phase.os.name", "posix"), \
                        mock.patch("run_build_phase.os.killpg", side_effect=signals, create=True) as killpg, \
                        mock.patch("run_build_phase.signal.SIGKILL", 9, create=True):
                    cleanup = _stop(process)
                self.assertEqual(cleanup.verified, expected)
                self.assertNotIn(mock.call(123, 0), killpg.call_args_list)
                self.assertTrue(all(call.args[1] in (signal.SIGTERM, 9)
                                    for call in killpg.call_args_list))

    def test_direct_child_cleanup_handles_all_signal_and_wait_races(self):
        scenarios = (
            ("terminate raced exit", ProcessLookupError, [0], None, True),
            ("terminate denied but exited", PermissionError, [0], None, True),
            ("grace expired then kill", None, [subprocess_timeout(), 0], None, True),
            ("kill raced exit", None, [subprocess_timeout(), 0], ProcessLookupError, True),
            ("kill denied but exited", None, [subprocess_timeout(), 0], PermissionError, True),
            ("kill denied still running", None, [subprocess_timeout(), subprocess_timeout()], PermissionError, False),
            ("both waits denied", PermissionError, [PermissionError, PermissionError], PermissionError, False),
            ("wait exit race", None, [ProcessLookupError], None, True),
        )
        for label, terminate_error, waits, kill_error, expected in scenarios:
            with self.subTest(label=label):
                process = mock.Mock(pid=123)
                process.poll.return_value = None
                process.terminate.side_effect = terminate_error
                process.kill.side_effect = kill_error
                process.wait.side_effect = waits
                warnings = []
                self.assertEqual(_stop_child(process, warnings), expected)
                self.assertLessEqual(process.wait.call_count, 2)
                if not expected:
                    self.assertIn("could not be verified", warnings[-1])

    def test_direct_child_poll_and_already_exited_wait_errors_are_bounded(self):
        process = mock.Mock(pid=123)
        process.poll.side_effect = PermissionError
        process.wait.return_value = 0
        warnings = []
        self.assertTrue(_stop_child(process, warnings))
        self.assertIn("Reading owned child state", warnings[0])
        process.terminate.assert_called_once()
        process = mock.Mock(pid=123)
        process.poll.return_value = 0
        process.wait.side_effect = subprocess_timeout()
        self.assertFalse(_stop_child(process, []))
        process.terminate.assert_not_called()
        process.kill.assert_not_called()

    def test_timeout_keeps_primary_status_when_cleanup_reports_or_raises_errors(self):
        from run_build_phase import _stop as real_stop
        for label, failure in (
            ("reported denial", _CleanupResult(False, ("PermissionError while stopping owned group.",))),
            ("unexpected OS denial", PermissionError()),
            ("unexpected wait timeout", subprocess_timeout()),
        ):
            with self.subTest(label=label):
                def stop(process):
                    real_stop(process)
                    if isinstance(failure, Exception):
                        raise failure
                    return failure
                with mock.patch("run_build_phase._stop", side_effect=stop):
                    self.assertEqual(self.run_code("import time; time.sleep(30)", timeout=.3), 124)
                status = json.loads(self.status.read_text())
                self.assertEqual((status["result"], status["exitCode"]), ("wall_timeout", 124))
                self.assertFalse(status["cleanupVerified"])
                self.assertTrue(status["cleanupWarnings"])

    def test_completed_child_with_unclosed_pipe_preserves_failure_or_rejects_success(self):
        # Model a child that exited but left a descendant holding stdout open.
        # The finite in-memory stream avoids leaking a real process on Windows.
        class HeldPipe(io.BytesIO):
            def read1(self, size):
                time.sleep(.25)
                return b""
        for code, expected_reason, expected_exit in (
            (0, "cleanup_failed", 125), (65, "command_failed", 65),
        ):
            with self.subTest(code=code):
                process = mock.Mock(pid=123, stdout=HeldPipe())
                process.poll.return_value = code
                # Explicitly hold the reader beyond the command's drain grace.
                with mock.patch("run_build_phase.subprocess.Popen", return_value=process), \
                        mock.patch("run_build_phase._stop", return_value=_CleanupResult(False, ("Group signal denied.",))), \
                        mock.patch("run_build_phase.queue.Queue.get", side_effect=queue.Empty):
                    self.assertEqual(self.run_code("unused", timeout=4), expected_exit)
                status = json.loads(self.status.read_text())
                self.assertEqual(status["result"], expected_reason)
                self.assertEqual(status["exitCode"], expected_exit)

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
