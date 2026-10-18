"""Bound a build command and retain its full output without flooding Actions.

Only processes owned by this invocation are stopped. The status file contains
no command arguments or environment values; compiler output stays in the log.
"""
from __future__ import annotations

import argparse
from collections import deque
from contextlib import contextmanager
from dataclasses import dataclass
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import threading
import time


@contextmanager
def _handle_termination():
    if threading.current_thread() is not threading.main_thread():
        yield
        return

    def cancelled(*_):
        raise KeyboardInterrupt

    previous = signal.signal(signal.SIGTERM, cancelled)
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous)


@dataclass(frozen=True)
class _CleanupResult:
    verified: bool
    warnings: tuple[str, ...] = ()


def _wait_child(process: subprocess.Popen, seconds: float, warnings: list[str]) -> bool:
    try:
        process.wait(timeout=seconds)
        return True
    except ProcessLookupError:
        return True
    except subprocess.TimeoutExpired:
        return False
    except OSError as error:
        warnings.append(f"Waiting for owned child failed ({type(error).__name__}).")
        return False


def _stop_child(process: subprocess.Popen, warnings: list[str]) -> bool:
    try:
        running = process.poll() is None
    except OSError as error:
        warnings.append(f"Reading owned child state failed ({type(error).__name__}).")
        running = True
    if not running:
        return _wait_child(process, 5, warnings)
    try:
        process.terminate()
    except ProcessLookupError:
        pass  # Exit between poll and signal is an ordinary cleanup race.
    except OSError as error:
        warnings.append(f"Terminating owned child failed ({type(error).__name__}).")
    if _wait_child(process, 2, warnings):
        return True
    try:
        process.kill()
    except ProcessLookupError:
        pass
    except OSError as error:
        warnings.append(f"Killing owned child failed ({type(error).__name__}).")
    if _wait_child(process, 5, warnings):
        return True
    warnings.append("Owned child termination could not be verified within the cleanup limit.")
    return False


def _stop(process: subprocess.Popen) -> _CleanupResult:
    warnings: list[str] = []
    group_stopped = os.name != "posix"
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            group_stopped = True
        except OSError as error:
            warnings.append(f"Terminating owned process group failed ({type(error).__name__}).")
        else:
            # Give the leader a bounded grace period, then stop descendants
            # even if their shell exited first. Do not probe with signal 0:
            # hosted macOS runners can reject that independent of TERM/KILL.
            _wait_child(process, 2, warnings)
        if not group_stopped:
            try:
                os.killpg(process.pid, signal.SIGKILL)
                group_stopped = True
            except ProcessLookupError:
                group_stopped = True
            except OSError as error:
                warnings.append(f"Killing owned process group failed ({type(error).__name__}).")
    child_stopped = _stop_child(process, warnings)
    return _CleanupResult(group_stopped and child_stopped, tuple(warnings))


def run_phase(name: str, command: list[str], log: Path, *, timeout: float,
              idle_timeout: float = 0, status: Path | None = None,
              heartbeat: float = 30) -> int:
    if not command or timeout <= 0 or idle_timeout < 0 or heartbeat <= 0:
        raise ValueError("A command and positive phase limits are required")
    log.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    last_output = started
    last_notice = started
    tail: deque[bytes] = deque(maxlen=12)
    output: queue.Queue[bytes | None] = queue.Queue()
    process = None
    reader = None
    eof = False
    result = 127
    reason = "launch_failed"
    cleanup = _CleanupResult(True)
    print(f"[{name}] Started. Full log: {log}", flush=True)

    def read_output() -> None:
        try:
            while block := process.stdout.read1(8192):
                output.put(block)
        finally:
            output.put(None)

    with _handle_termination(), log.open("wb") as handle:
        try:
            process = subprocess.Popen(
                command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                start_new_session=os.name == "posix",
            )
            reader = threading.Thread(target=read_output, daemon=True)
            reader.start()
            ended = None
            while True:
                now = time.monotonic()
                try:
                    block = output.get(timeout=0.1)
                    if block is None:
                        eof = True
                    else:
                        handle.write(block)
                        handle.flush()
                        tail.append(block)
                        last_output = now
                except queue.Empty:
                    pass
                code = process.poll()
                if code is not None:
                    ended = ended or now
                    if eof or now - ended >= 1:
                        result = code if code >= 0 else 128 - code
                        reason = "passed" if code == 0 else "command_failed"
                        break
                if now - started >= timeout:
                    result, reason = 124, "wall_timeout"
                    break
                if idle_timeout and now - last_output >= idle_timeout:
                    result, reason = 124, "idle_timeout"
                    break
                if now - last_notice >= heartbeat:
                    print(f"[{name}] {int(now - started)}s elapsed; "
                          f"last output {int(now - last_output)}s ago.", flush=True)
                    last_notice = now
        except OSError as error:
            # Do not echo arguments, which can contain credentials.
            handle.write(f"Could not start build command ({type(error).__name__}).\n".encode())
        except KeyboardInterrupt:
            result, reason = 130, "interrupted"
        finally:
            # A completed tool needs no signal. In particular, never signal a
            # reaped process group after a normal compiler/analyzer exit.
            if process is not None and (reason not in ("passed", "command_failed") or not eof):
                try:
                    cleanup = _stop(process)
                except (OSError, subprocess.TimeoutExpired) as error:
                    # Cleanup must never hide the command's primary failure or
                    # prevent its diagnostic receipt from being written.
                    cleanup = _CleanupResult(False, (
                        f"Owned process cleanup failed ({type(error).__name__}).",))
            if reader is not None:
                reader.join(timeout=3)
                if reader.is_alive():
                    cleanup = _CleanupResult(False, cleanup.warnings + (
                        "Build output pipe remained open after the cleanup limit.",))
            if process is not None and (reader is None or not reader.is_alive()):
                try:
                    process.stdout.close()
                except OSError as error:
                    cleanup = _CleanupResult(False, cleanup.warnings + (
                        f"Closing build output failed ({type(error).__name__}).",))
            while True:
                try:
                    block = output.get_nowait()
                except queue.Empty:
                    break
                if block is None:
                    eof = True
                elif block:
                    handle.write(block)
                    tail.append(block)

            for warning in cleanup.warnings:
                handle.write(("Cleanup warning: " + warning + "\n").encode())
                print(f"[{name}] Cleanup warning: {warning}", file=sys.stderr, flush=True)
            if result == 0 and not cleanup.verified:
                result, reason = 125, "cleanup_failed"

    duration = round(time.monotonic() - started, 3)
    if status is not None:
        status.parent.mkdir(parents=True, exist_ok=True)
        pending = status.with_name(status.name + ".pending")
        pending.write_text(json.dumps({
            "phase": name, "result": reason, "exitCode": result,
            "elapsedSeconds": duration, "wallLimitSeconds": timeout,
            "idleLimitSeconds": idle_timeout, "log": str(log),
            "cleanupVerified": cleanup.verified,
            "cleanupWarnings": list(cleanup.warnings),
        }, indent=2) + "\n", encoding="utf-8")
        pending.replace(status)
    print(f"[{name}] {reason}; exit={result}; elapsed={duration}s.", flush=True)
    if result:
        lines = b"".join(tail).decode("utf-8", errors="replace").splitlines()
        print("\n".join(lines[-60:]), file=sys.stderr, flush=True)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--timeout", required=True, type=float)
    parser.add_argument("--idle-timeout", type=float, default=0)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--status", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    return run_phase(args.name, command, args.log, timeout=args.timeout,
                     idle_timeout=args.idle_timeout, status=args.status)


if __name__ == "__main__":
    sys.exit(main())
