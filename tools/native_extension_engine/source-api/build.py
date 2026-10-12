"""Compile pinned Suwayomi extension API implementations for a Java 8 host.

The upstream server targets a newer JVM. This build compiles only its reviewed
source API and shared network helpers; it never rewrites class-file versions.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
MANIFEST = json.loads((HERE / "upstream.json").read_text(encoding="utf-8"))
DEFAULT_WORK = HERE.parents[2] / "artifacts" / "native-source-api-build"


def verified_fetch(url: str, target: Path, expected: str) -> Path:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_file() and hashlib.sha256(target.read_bytes()).hexdigest() == expected:
        return target
    with urllib.request.urlopen(url, timeout=90) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"Pinned source/dependency checksum mismatch: {url}")
    pending = target.with_name(target.name + ".pending")
    pending.write_bytes(data)
    pending.replace(target)
    return target


def compile_api(dependencies: Path, java: str, work: Path) -> dict:
    compiler_dir = work / "compiler"
    source_dir = work / "upstream-source"
    jobs: list[tuple[str, Path, str]] = []
    for item in MANIFEST["compiler"]:
        jobs.append((item["url"], compiler_dir / item["name"], item["sha256"]))
    for item in MANIFEST["files"]:
        url = (f"https://raw.githubusercontent.com/Suwayomi/Suwayomi-Server/"
               f"{MANIFEST['commit']}/{item['path']}")
        jobs.append((url, source_dir / item["path"], item["sha256"]))
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(lambda job: verified_fetch(*job), jobs))

    # NetworkHelper is implemented by the maintained host, not by the server's
    # desktop networking service. kotlinc reads this Java declaration but does
    # not package it; javac compiles it with the rest of the host separately.
    network_helper = HERE.parent / "java/eu/kanade/tachiyomi/network/NetworkHelper.java"
    classes = work / "classes"
    if classes.exists():
        # Only remove our generated class output, after verifying the location.
        resolved = classes.resolve()
        if resolved.parent != work.resolve() or resolved.name != "classes":
            raise ValueError("Unexpected generated classes directory")
        shutil.rmtree(resolved)
    classes.mkdir(parents=True)
    compiler_cp = os.pathsep.join(str(compiler_dir / x["name"]) for x in MANIFEST["compiler"])
    source_files = sorted(str(source_dir / x["path"]) for x in MANIFEST["files"]
                          if x["path"].endswith(".kt"))
    command = [java, "-cp", compiler_cp, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
               "-no-stdlib", "-no-reflect", "-Xjdk-release=8", "-jvm-default=enable",
               "-opt-in=kotlinx.serialization.ExperimentalSerializationApi",
               "-classpath", str(dependencies.resolve()),
               "-module-name", "tachibooks_source_api", "-d", str(classes),
               *source_files, str(network_helper)]
    subprocess.run(command, check=True)

    output = work / "extension-source-api-java8.jar"
    majors: dict[int, int] = {}
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(classes.rglob("*")):
            if not file.is_file():
                continue
            data = file.read_bytes()
            if file.suffix == ".class":
                major = struct.unpack(">H", data[6:8])[0]
                if major > 52:
                    raise ValueError(f"Non-Java8 bytecode emitted: {file} ({major})")
                majors[major] = majors.get(major, 0) + 1
            info = zipfile.ZipInfo(file.relative_to(classes).as_posix(), (2000, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
        for item in MANIFEST["files"]:
            if item["path"].endswith("LICENSE"):
                name = "META-INF/licenses/" + item["path"].replace("/", "_")
                info = zipfile.ZipInfo(name, (2000, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, (source_dir / item["path"]).read_bytes())
    proof = {"repository": MANIFEST["repository"], "tag": MANIFEST["tag"],
             "commit": MANIFEST["commit"], "compiler": "Kotlin 2.4.10",
             "jdkRelease": 8, "classMajors": majors,
             "sourceFiles": [x for x in MANIFEST["files"] if x["path"].endswith(".kt")],
             "networkHelperDeclarationSha256": hashlib.sha256(network_helper.read_bytes()).hexdigest(),
             "dependenciesSha256": hashlib.sha256(dependencies.read_bytes()).hexdigest(),
             "output": str(output.resolve()), "bytes": output.stat().st_size,
             "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
             "runtimeVerification": "not performed by compilation"}
    (work / "source-api-provenance.json").write_text(json.dumps(proof, indent=2) + "\n", encoding="utf-8")
    return proof


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dependencies", type=Path, required=True)
    parser.add_argument("--java", default="java")
    parser.add_argument("--work", type=Path, default=DEFAULT_WORK)
    args = parser.parse_args()
    result = compile_api(args.dependencies, args.java, args.work.resolve())
    print(json.dumps({key: result[key] for key in
                      ("commit", "compiler", "jdkRelease", "classMajors", "output", "bytes", "sha256")}, indent=2))


if __name__ == "__main__":
    main()
