"""Bounded regression matrix for genuine APKs against the maintained Java host.

This probes install/factories/preferences/restart, not website flows or iOS JNI.
The runner starts no server and calls no website search/read/download operation;
original factory code may initiate its own startup requests. APKs remain original.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
MAX_CASES = 8
MAX_APK_BYTES = 32 * 1024 * 1024
PREFIX = "TACHI_COVERAGE\t"
NATIVE_JVM_OPTIONS = ["-Xint", "-Xms16m", "-Xmx128m", "-Xss512k",
                      "-XX:-UseCompressedOops", "-XX:-UseCompressedClassPointers"]
RUNTIME_ERROR = re.compile(
    r"TACHI_UNCAUGHT\t|\bStub!|\b(?:VerifyError|NoClassDefFoundError|ClassNotFoundException|"
    r"UnsatisfiedLinkError|NoSuchMethodError|NoSuchFieldError|IncompatibleClassChangeError|"
    r"AbstractMethodError|ExceptionInInitializerError|NullPointerException)\b|"
    r"\b(?:JNI|Jni)[A-Za-z0-9_.]*(?:Error|Exception|Metadata)\b|"
    r"(?:No|Missing) (?:BuiltInsLoader|MetadataExtensions|JNI)|"
    r"(?:BuiltInsLoader|MetadataExtensions|native library).*(?:not found|could not|failed|missing)",
    re.IGNORECASE,
)


class CoverageRuntimeFailure(ValueError):
    def __init__(self, message: str, diagnostics: list[str]):
        super().__init__(message)
        self.diagnostics = diagnostics


def runtime_diagnostics(stdout: str, stderr: str) -> list[str]:
    diagnostics = []
    for line in (stdout + "\n" + stderr).splitlines():
        # RPC errors are evaluated separately. Only console/runtime evidence is
        # scanned here, including asynchronous errors outside the RPC envelope.
        if not line.startswith(PREFIX) and RUNTIME_ERROR.search(line):
            excerpt = line[:1200]
            if excerpt not in diagnostics:
                diagnostics.append(excerpt)
            if len(diagnostics) == 16:
                break
    return diagnostics


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def classpath_fingerprint(path: Path) -> str:
    if path.is_file():
        return sha256(path)
    digest = hashlib.sha256()
    for child in sorted(path.rglob("*.class")):
        digest.update(child.relative_to(path).as_posix().encode("utf-8") + b"\0")
        digest.update(bytes.fromhex(sha256(child)))
    return digest.hexdigest()


def snapshot_classpath(paths: list[Path], directory: Path) -> list[Path]:
    directory.mkdir()
    result = []
    for index, source in enumerate(paths):
        expected = classpath_fingerprint(source)
        target = directory / (str(index) + "-" + source.name)
        if source.is_dir():
            shutil.copytree(source, target)
        else:
            shutil.copyfile(source, target)
        if classpath_fingerprint(target) != expected or classpath_fingerprint(source) != expected:
            raise ValueError("Compiled host changed while capturing the coverage classpath")
        result.append(target)
    return result


def load_matrix(path: Path) -> dict:
    matrix = json.loads(path.read_text(encoding="utf-8"))
    if matrix.get("version") != 1:
        raise ValueError("Unsupported coverage matrix version")
    cases = matrix.get("cases")
    if not isinstance(cases, list) or not 1 <= len(cases) <= MAX_CASES:
        raise ValueError(f"A matrix must contain 1..{MAX_CASES} cases")
    seen = set()
    for case in cases:
        name = case.get("case")
        if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9-]{1,80}", name) or name in seen:
            raise ValueError("Invalid or duplicate case name")
        seen.add(name)
        if not re.fullmatch(r"[a-f0-9]{64}", case.get("sha256", "")):
            raise ValueError("An original APK checksum is required")
        size = case.get("bytes")
        if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= MAX_APK_BYTES:
            raise ValueError("Invalid original APK size")
        if not re.fullmatch(r"eu\.kanade\.tachiyomi\.extension\.[A-Za-z0-9_.]+", case.get("packageName", "")):
            raise ValueError("Invalid extension package name")
        ids = case.get("sourceIds")
        if not isinstance(ids, list) or not ids or len(ids) > 2048:
            raise ValueError("Source identities must be nonempty and unique")
        for identity in ids:
            if not isinstance(identity, str) or not re.fullmatch(r"-?\d{1,19}", identity) or not -(2**63) <= int(identity) < 2**63:
                raise ValueError("Source identities must preserve signed 64-bit strings")
        if len(set(ids)) != len(ids):
            raise ValueError("Source identities must be nonempty and unique")
        url = case.get("url", "")
        if url and not re.fullmatch(r"https://github\.com/keiyoushi/extensions/releases/download/[^/?#]+/[^/?#]+\.apk", url):
            raise ValueError("Coverage fetches only pinned original Keiyoushi APK releases")
        if not url and not case.get("localApk"):
            raise ValueError("An APK release or explicit local fixture is required")
    return matrix


def verify_apk(path: Path, case: dict) -> None:
    if not path.is_file() or path.stat().st_size != case["bytes"] or sha256(path) != case["sha256"]:
        raise ValueError("Original APK checksum/size mismatch")
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) > 100000 or len(set(names)) != len(names) or sum(item.file_size for item in archive.infolist()) > 128 * 1024 * 1024:
            raise ValueError("Original APK archive exceeds bounded entry/expanded-size limits")
        if "AndroidManifest.xml" not in names or not any(re.fullmatch(r"classes\d*\.dex", name) for name in names):
            raise ValueError("Fixture is not an original Android extension APK")
        if archive.testzip() is not None:
            raise ValueError("Original APK CRC failed")


def obtain_apk(case: dict, cache: Path, fetch: bool) -> Path:
    if case.get("localApk"):
        source = (ROOT / case["localApk"]).resolve()
        verify_apk(source, case)
        return source
    target = cache / (case["sha256"] + ".apk")
    if target.exists():
        verify_apk(target, case)
        return target
    if not fetch:
        raise ValueError("Original APK is not cached; use --fetch for this bounded matrix")
    cache.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".download-", suffix=".apk", dir=cache)
    os.close(descriptor)
    pending = Path(temporary)
    try:
        request = urllib.request.Request(case["url"], headers={"User-Agent": "TachiBooks-extension-coverage/1"})
        with urllib.request.urlopen(request, timeout=30) as response, pending.open("wb") as stream:
            count = 0
            while block := response.read(32768):
                count += len(block)
                if count > case["bytes"] or count > MAX_APK_BYTES:
                    raise ValueError("Original APK download exceeded the pinned size")
                stream.write(block)
            stream.flush()
            os.fsync(stream.fileno())
        verify_apk(pending, case)
        os.replace(pending, target)
        return target
    finally:
        pending.unlink(missing_ok=True)


def requests_for(case: dict, data: Path, apk: Path | None) -> list[dict]:
    requests = [{"method": "initialize", "args": {"dataDirectory": str(data.resolve())}}]
    if apk is not None:
        requests.append({"method": "install", "args": {
            "apkPath": str(apk.resolve()), "packageHash": case["sha256"],
            "packageUrl": case.get("url", ""), "iconUrl": case.get("iconUrl", ""),
        }})
    requests.extend([{"method": "extensions", "args": {}}, {"method": "sources", "args": {}}])
    # All factory IDs are checked. Preference construction is bounded to three languages.
    for identity in case["sourceIds"][:3]:
        requests.append({"method": "preferences", "args": {"sourceId": identity}})
    return requests


def parse_responses(stdout: str, requests: list[dict]) -> list[dict]:
    lines = [line[len(PREFIX):] for line in stdout.splitlines() if line.startswith(PREFIX)]
    if len(lines) != len(requests):
        raise ValueError("Host transport returned an incomplete operation sequence")
    responses = []
    for request, line in zip(requests, lines):
        value = json.loads(line)
        if not isinstance(value, dict) or not isinstance(value.get("ok"), bool):
            raise ValueError("Host returned a malformed response")
        responses.append({"method": request["method"], "args": request["args"], "response": value})
    return responses


def evaluate_phase(case: dict, operations: list[dict], installed: bool) -> dict:
    failures = []
    results = {}
    preferences = {}
    for operation in operations:
        method, response = operation["method"], operation["response"]
        if response.get("ok") is not True:
            failures.append({"method": method, "sourceId": operation["args"].get("sourceId"), "error": response.get("error")})
        elif method == "preferences":
            preferences[operation["args"]["sourceId"]] = response.get("result")
        else:
            results[method] = response.get("result")
    extension = results.get("install") if installed else None
    listed = results.get("extensions", [])
    if isinstance(listed, list):
        matches = [item for item in listed if isinstance(item, dict) and item.get("id") == case["packageName"]]
        if len(matches) == 1 and len(listed) == 1:
            extension = matches[0]
        else:
            failures.append({"method": "extensions", "error": "Expected exactly one original package"})
    else:
        failures.append({"method": "extensions", "error": "Malformed extension list"})
    if not isinstance(extension, dict) or extension.get("installed") is not True:
        failures.append({"method": "extensions", "error": "Original package is not loaded"})
    elif extension.get("version") != case["versionName"] or extension.get("apkSha256") != case["sha256"]:
        failures.append({"method": "extensions", "error": "Original package version/checksum changed"})
    else:
        persisted_ids = extension.get("sourceIds")
        if not isinstance(persisted_ids, list) or any(not isinstance(item, str) for item in persisted_ids) or sorted(persisted_ids) != sorted(case["sourceIds"]):
            failures.append({"method": "extensions", "error": "Persisted package source identities changed"})
    source_ids = []
    sources = results.get("sources", [])
    if not isinstance(sources, list) or any(not isinstance(item, dict) or not isinstance(item.get("id"), str) for item in sources):
        failures.append({"method": "sources", "error": "Source identity lost its String representation"})
    else:
        source_ids = [item["id"] for item in sources]
        if sorted(source_ids) != sorted(case["sourceIds"]):
            failures.append({"method": "sources", "error": "Factory IDs differ from the original catalogue", "actualIds": source_ids})
    for identity, items in preferences.items():
        if not isinstance(items, list) or any(not isinstance(item, dict) or not isinstance(item.get("key"), str) for item in items):
            failures.append({"method": "preferences", "sourceId": identity, "error": "Malformed preference metadata"})
    return {"passed": not failures, "sourceCount": len(source_ids), "sourceIds": source_ids,
            "preferenceCounts": {key: len(value) if isinstance(value, list) else None for key, value in preferences.items()},
            "preferences": preferences, "failures": failures}


def run_phase(java: Path, classpath: list[Path], requests: list[dict], log: Path, timeout: int, background_seconds: int) -> list[dict]:
    try:
        process = subprocess.run(
            [str(java), *NATIVE_JVM_OPTIONS, "-cp", os.pathsep.join(map(str, classpath)), "HostCoverageBridge", str(background_seconds * 1000)],
            input="".join(json.dumps(value, ensure_ascii=True) + "\n" for value in requests),
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout,
        )
    except subprocess.TimeoutExpired as failure:
        captured = (failure.stdout or b"") + b"\nSTDERR\n" + (failure.stderr or b"")
        log.write_bytes(captured)
        raise
    log.write_text(process.stdout + "\nSTDERR\n" + process.stderr, encoding="utf-8")
    diagnostics = runtime_diagnostics(process.stdout, process.stderr)
    if process.returncode or diagnostics:
        raise CoverageRuntimeFailure(f"Host JVM exit {process.returncode} or runtime diagnostics failed; inspect {log.name}", diagnostics)
    if f"TACHI_BACKGROUND_OBSERVED\t{background_seconds * 1000}" not in process.stdout.splitlines():
        raise ValueError("Host exited before its bounded background observation completed")
    return parse_responses(process.stdout, requests)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matrix", type=Path, default=HERE / "matrix.json")
    parser.add_argument("--case", action="append", default=[])
    parser.add_argument("--runtime", type=Path, help="Prepared Runtime/engine directory containing the maintained JARs")
    parser.add_argument("--classpath", type=Path, action="append", default=[])
    parser.add_argument("--java", type=Path, required=True)
    parser.add_argument("--javac", type=Path, required=True)
    parser.add_argument("--fetch", action="store_true", help="Fetch only missing pinned matrix APKs (maximum eight)")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--background-seconds", type=int, default=3, help="Observe factory tasks for 1..10 seconds after each phase")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/extension-coverage-report.json")
    args = parser.parse_args()
    matrix = load_matrix(args.matrix)
    names = {case["case"] for case in matrix["cases"]}
    if set(args.case) - names:
        parser.error("Unknown matrix case")
    if not 10 <= args.timeout <= 300:
        parser.error("Timeout must be between 10 and 300 seconds")
    if not 1 <= args.background_seconds <= 10:
        parser.error("Background observation must be between 1 and 10 seconds")
    classpath = [path.resolve() for path in args.classpath]
    if args.runtime:
        # Match JNI's classpath: maintained host API/Android/Zstd overrides precede
        # the original dependency classes. Alphabetical order reverses this.
        classpath.extend(sorted(args.runtime.resolve().glob("*.jar"), key=lambda path: (path.name != "extension-host.jar", path.name)))
    if not classpath or any(not path.exists() for path in classpath):
        parser.error("A prepared real host classpath is required")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    run_directory = Path(tempfile.mkdtemp(prefix="extension-coverage-", dir=args.output.parent))
    original_classpath = classpath
    classpath = snapshot_classpath(classpath, run_directory / "classpath")
    bridge = run_directory / "bridge"
    bridge.mkdir()
    compile_result = subprocess.run([
        str(args.javac), "--release", "8", "-encoding", "UTF-8",
        "-cp", os.pathsep.join(map(str, classpath)), "-d", str(bridge),
        str(HERE / "HostCoverageBridge.java"), str(HERE / "CompressionCoverageProof.java"),
    ], capture_output=True, timeout=60)
    if compile_result.returncode:
        raise RuntimeError("Coverage transport did not compile: " + compile_result.stderr.decode("utf-8", errors="replace"))
    classpath.insert(0, bridge)
    version = subprocess.run([str(args.java), "-Xint", "-version"], capture_output=True, timeout=15)
    report = {
        "version": 1, "scope": "genuine-original-apk-install-factory-preferences-restart",
        "iosRuntimeVerified": False, "websiteSearchReadDownloadVerified": False,
        "sourceStartupMayRequestNetwork": True, "backgroundObservationSecondsPerPhase": args.background_seconds,
        "jvmOptions": NATIVE_JVM_OPTIONS,
        "allExtensionsVerified": False, "javaVersion": (version.stdout + version.stderr).decode("utf-8", errors="replace").strip(),
        "classPath": [{"path": str(path), "sha256": classpath_fingerprint(path)} for path in classpath[1:]],
        "classPathSource": [str(path) for path in original_classpath],
        "matrixSha256": sha256(args.matrix), "catalogue": matrix.get("catalogue"), "runDirectory": str(run_directory), "cases": [],
    }
    try:
        compression = subprocess.run([
            str(args.java), *NATIVE_JVM_OPTIONS, "-cp", os.pathsep.join(map(str, classpath)),
            "CompressionCoverageProof", str(HERE / "compression-fixtures.json"),
        ], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
        (run_directory / "compression.log").write_text(compression.stdout + "\nSTDERR\n" + compression.stderr, encoding="utf-8")
        lines = [line.split("\t", 1)[1] for line in compression.stdout.splitlines() if line.startswith("TACHI_COMPRESSION\t")]
        if compression.returncode != 0 or len(lines) != 1:
            raise ValueError("Maintained decoder proof failed; inspect compression.log")
        report["compression"] = json.loads(lines[0])
    except (ValueError, OSError, subprocess.TimeoutExpired) as failure:
        report["compression"] = {"passed": False, "error": {"type": type(failure).__name__, "message": str(failure)}}
    for case in matrix["cases"]:
        if args.case and case["case"] not in args.case:
            continue
        start = time.monotonic()
        result = {"case": case["case"], "packageName": case["packageName"], "versionName": case["versionName"],
                  "api": case["api"], "categories": case.get("categories", []), "apkSha256": case["sha256"], "passed": False}
        try:
            apk = obtain_apk(case, ROOT / "artifacts/extension-coverage-apks", args.fetch)
            data = run_directory / case["case"]
            install = evaluate_phase(case, run_phase(args.java, classpath, requests_for(case, data, apk), run_directory / (case["case"] + "-install.log"), args.timeout, args.background_seconds), True)
            restart = evaluate_phase(case, run_phase(args.java, classpath, requests_for(case, data, None), run_directory / (case["case"] + "-restart.log"), args.timeout, args.background_seconds), False)
            same = install["preferences"] == restart["preferences"]
            # Keep counts/errors in the public report, not arbitrary preference values.
            install.pop("preferences")
            restart.pop("preferences")
            result.update({"install": install, "restart": restart, "preferencesStableAfterRestart": same,
                           "passed": install["passed"] and restart["passed"] and same})
        except (ValueError, OSError, subprocess.TimeoutExpired, zipfile.BadZipFile) as failure:
            result["error"] = {"type": type(failure).__name__, "message": str(failure)}
            if isinstance(failure, CoverageRuntimeFailure):
                result["runtimeDiagnostics"] = failure.diagnostics
        result["seconds"] = round(time.monotonic() - start, 3)
        report["cases"].append(result)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(case["case"], "PASS" if result["passed"] else "FAIL", flush=True)
    report["passed"] = report["compression"].get("passed") is True and bool(report["cases"]) and all(case["passed"] for case in report["cases"])
    report["counts"] = {"selected": len(report["cases"]), "passed": sum(case["passed"] for case in report["cases"])}
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(str(args.output), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
