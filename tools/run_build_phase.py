"""Bound a build command and retain its full output without flooding Actions.

Only processes owned by this invocation are stopped. The status file contains
no command arguments or environment values; compiler output stays in the log.
"""
from __future__ import annotations

import argparse
from collections import deque
from contextlib import contextmanager
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


def _stop(process: subprocess.Popen) -> None:
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        except PermissionError:
            # Some hosted macOS runners deny group signalling. Preserve the
            # phase result and fall back to the direct child we actually own.
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            return
        # A shell can exit before its compiler children. Always stop the group.
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            process.poll()  # Reap the leader before checking surviving children.
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    elif process.poll() is None:
        process.kill()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


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
                _stop(process)
            if reader is not None:
                reader.join(timeout=3)
            if process is not None and (reader is None or not reader.is_alive()):
                process.stdout.close()
            while True:
                try:
                    block = output.get_nowait()
                except queue.Empty:
                    break
                if block:
                    handle.write(block)
                    tail.append(block)

    duration = round(time.monotonic() - started, 3)
    if status is not None:
        status.parent.mkdir(parents=True, exist_ok=True)
        pending = status.with_name(status.name + ".pending")
        pending.write_text(json.dumps({
            "phase": name, "result": reason, "exitCode": result,
            "elapsedSeconds": duration, "wallLimitSeconds": timeout,
            "idleLimitSeconds": idle_timeout, "log": str(log),
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
