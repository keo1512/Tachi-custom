"""Build the Java 8 host from reviewed source and pinned upstream dependencies.

Modern libraries retain their original class bytes. The separate source-api
builder legitimately recompiles the reviewed Kotlin API for the Java 8 VM.
"""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import zipfile

LEGACY_DEPENDENCY_URL = "https://github.com/Suwayomi/Suwayomi-Server/releases/download/v0.7.0/Tachidesk-Server-v0.7.0-r1197.jar"
LEGACY_DEPENDENCY_BYTES = 224_401_325
LEGACY_DEPENDENCY_SHA256 = "e033b55a2042bbff32a45809741984c105d0d716960256edf0de5310ba265550"
DEPENDENCY_URL = "https://github.com/Suwayomi/Suwayomi-Server/releases/download/v2.4.2366/Suwayomi-Server-v2.4.2366.jar"
DEPENDENCY_BYTES = 182_952_426
DEPENDENCY_SHA256 = "af9feb20af9d7ebe9e30769e6c6ebc7fc7ab1c447388d42e0280b1da5fe07bfd"
ARRAY_DECODER_RESOURCE = "res/Hex.class"
ARRAY_DECODER_BYTES = 2326
ARRAY_DECODER_SHA256 = "34aaebb87071092ceb06033a016a19be38d3882b21094b2acbaec7694c60da73"
PREFIXES = (
    "uy/kohesive/injekt/", "kotlin/",
    "kotlinx/serialization/", "kotlinx/coroutines/", "okhttp3/", "okio/", "rx/",
    "org/jsoup/", "org/koin/", "co/touchlab/", "org/brotli/", "com/squareup/zstd/",
    "com/google/gson/", "com/fasterxml/", "org/slf4j/", "org/intellij/",
    "org/jetbrains/", "org/xmlpull/", "com/cedarsoftware/", "org/apache/commons/",
    "com/googlecode/d2j/", "com/googlecode/dex2jar/", "org/objectweb/asm/",
    "net/dongliu/apk/parser/",
)
LEGACY_PREFIXES = (
    "android/", "androidx/", "xyz/nulldev/androidcompat/",
    "com/google/gson/", "com/fasterxml/",
)
RESOURCES = {
    "r_values.ini", "r_styles.ini",
    # Dex2Asm reads this class as a template resource and injects its primitive
    # array decoders into converted extension classes. It silently omits the
    # methods when the resource is absent, leaving linkage failures at runtime.
    ARRAY_DECODER_RESOURCE,
    "META-INF/services/kotlin.reflect.jvm.internal.impl.builtins.BuiltInsLoader",
    "META-INF/services/kotlin.reflect.jvm.internal.impl.km.internal.extensions.MetadataExtensions",
    "META-INF/services/kotlin.reflect.jvm.internal.impl.resolve.ExternalOverridabilityCondition",
}
# These compile-time-only Android annotation markers were emitted for Java 9;
# the extension host does not inspect them and Java 8 cannot load their bytecode.
COMPILE_ONLY = {
    "androidx/annotation/RecentlyNullable.class",
    "androidx/annotation/RecentlyNonNull.class",
}
# The upstream desktop archive includes Android-only coroutine dispatchers;
# Android's Looper is absent on iOS. Dispatchers.IO/Default remain unchanged.
ANDROID_ONLY = {
    "kotlinx/coroutines/android/AndroidDispatcherFactory.class",
    "kotlinx/coroutines/android/HandlerContext.class",
    "kotlinx/coroutines/android/HandlerDispatcher.class",
    "kotlinx/coroutines/android/HandlerDispatcherKt.class",
}


def sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def verify_dependency_archive(path: Path) -> None:
    if path.stat().st_size != DEPENDENCY_BYTES or sha256(path) != DEPENDENCY_SHA256:
        raise ValueError("Official Java dependency archive size or SHA-256 mismatch")


def legal_file(name: str) -> bool:
    lower = name.lower()
    return not lower.endswith(("/", ".class")) and (
        "/" not in name and ("license" in lower or "notice" in lower)
        or lower.startswith(("meta-inf/license", "meta-inf/notice", "notices/"))
        or lower == "okhttp3/internal/publicsuffix/notice"
    )


def put_member(target: zipfile.ZipFile, name: str, data: bytes) -> None:
    info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    target.writestr(info, data)


def upstream_members(source: zipfile.ZipFile) -> dict[str, bytes]:
    """Read the pinned desktop fat archive's last-entry class selection.

    Its shadow packaging contains duplicate upstream notices and deliberately
    transformed ASM classes. Retain every distinct notice under its own name;
    the archive hash fixes the class selection so it cannot change silently.
    User-downloaded extension ZIPs are validated separately and reject duplicates.
    """
    infos = source.infolist()
    groups: dict[int, list[zipfile.ZipInfo]] = {}
    for info in infos:
        groups.setdefault(info.header_offset, []).append(info)
    offsets = sorted(groups)
    ends = {
        offset: offsets[index + 1] if index + 1 < len(offsets) else source.start_dir
        for index, offset in enumerate(offsets)
    }
    for offset, aliases in groups.items():
        if len(aliases) < 2:
            continue
        # Shadow can repeat central-directory records for one physical member.
        # Python 3.12.7 treats the zero-length inferred boundary as an overlap;
        # newer Python recognizes this alias. Accept only identical metadata,
        # and retain the boundary at the next distinct physical local header.
        signatures = {
            (info.orig_filename, info.filename, info.CRC, info.file_size,
             info.compress_size, info.compress_type, info.flag_bits,
             info.extract_version)
            for info in aliases
        }
        if len(signatures) != 1 or offset < 0 or ends[offset] <= offset:
            raise zipfile.BadZipFile("Conflicting upstream central-directory aliases")
    result: dict[str, bytes] = {}
    for index, original in enumerate(infos):
        if original.is_dir():
            continue
        info = original
        if len(groups[info.header_offset]) > 1:
            # Do not mutate the archive's ZipInfo objects or disable its overlap
            # protection. ZipFile still validates local names, lengths and CRC.
            info = copy.copy(info)
            info._end_offset = ends[info.header_offset]
        data = source.read(info)
        if legal_file(info.filename) and info.filename in result:
            if result[info.filename] != data:
                result["META-INF/licenses/shadow-" + str(index) + "-" + info.filename.replace("/", "_")] = data
        else:
            result[info.filename] = data
    return result


def build_dependencies(archive: Path, output: Path, legacy: Path) -> dict:
    verify_dependency_archive(archive)
    output.parent.mkdir(parents=True, exist_ok=True)
    majors: dict[int, int] = {}
    class_count = resource_count = 0
    if legacy.stat().st_size != LEGACY_DEPENDENCY_BYTES or sha256(legacy) != LEGACY_DEPENDENCY_SHA256:
        raise ValueError("Official Android compatibility archive size or SHA-256 mismatch")
    members: dict[str, bytes] = {}
    with zipfile.ZipFile(archive) as source:
        original = upstream_members(source)
        names = original.keys()
        selected = sorted(name for name in names if not name.endswith("/")
                          and not name.endswith("module-info.class")
                          and name not in COMPILE_ONLY
                          and name not in ANDROID_ONLY
                          and not name.startswith("rx/android/")
                          and (name.startswith(PREFIXES) or name in RESOURCES or legal_file(name)
                               or name.endswith(".kotlin_module")))
        for name in selected:
            data = original[name]  # stdlib verifies each member's CRC.
            # Pack200 is unavailable on this runtime and is unused by APK
            # conversion; retain the generic Commons Compress implementations.
            if name.startswith("org/apache/commons/compress/java/util/jar/Pack200"):
                continue
            members[name] = data
    with zipfile.ZipFile(legacy) as source:
        original = upstream_members(source)
        for name in sorted(original):
            if name.endswith("/") or name in COMPILE_ONLY:
                continue
            if name.startswith(LEGACY_PREFIXES) or name in RESOURCES or legal_file(name):
                if legal_file(name) and name in members and members[name] != original[name]:
                    members["META-INF/licenses/legacy-" + name.replace("/", "_")] = original[name]
                else:
                    members.setdefault(name, original[name])
    if ARRAY_DECODER_RESOURCE not in members:
        raise ValueError("Dex2jar primitive-array decoder template is missing")
    with zipfile.ZipFile(output, "w") as target:
        for name, data in sorted(members.items()):
            if name.endswith(".class"):
                if data[:4] != b"\xca\xfe\xba\xbe":
                    raise ValueError("Invalid dependency class")
                major = int.from_bytes(data[6:8], "big")
                if major > 52:
                    raise ValueError("Dependency requires Java newer than the bundled Java 8 VM: " + name)
                majors[major] = majors.get(major, 0) + 1
                class_count += 1
            else:
                resource_count += 1
            put_member(target, name, data)
    return {"upstreamUrl": DEPENDENCY_URL, "upstreamSha256": DEPENDENCY_SHA256,
            "androidCompatibilityUrl": LEGACY_DEPENDENCY_URL,
            "androidCompatibilitySha256": LEGACY_DEPENDENCY_SHA256,
            "sha256": sha256(output), "classes": class_count,
            "resources": resource_count, "classMajors": majors}


def build_api(dependencies: Path, work: Path, java: str) -> tuple[Path, dict]:
    path = Path(__file__).resolve().parent / "source-api/build.py"
    spec = importlib.util.spec_from_file_location("tachibooks_source_api_builder", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    proof = module.compile_api(dependencies, java, work)
    return Path(proof["output"]), proof


def merge_api(dependencies: Path, api: Path) -> None:
    members: dict[str, bytes] = {}
    with zipfile.ZipFile(dependencies) as source:
        members.update((name, source.read(name)) for name in source.namelist())
    with zipfile.ZipFile(api) as source:
        for name in source.namelist():
            if name in members:
                raise ValueError("Source API conflicts with dependency entry: " + name)
            members[name] = source.read(name)
    pending = dependencies.with_name(dependencies.name + ".pending")
    with zipfile.ZipFile(pending, "w") as target:
        for name, data in sorted(members.items()):
            put_member(target, name, data)
    pending.replace(dependencies)


def merge_portable_zstd(dependencies: Path, decoder: Path, notice: Path) -> dict:
    members: dict[str, bytes] = {}
    with zipfile.ZipFile(dependencies) as source:
        members.update((name, source.read(name)) for name in source.namelist())
    with zipfile.ZipFile(decoder) as source:
        for name in source.namelist():
            if name.endswith("/") or not name.startswith("io/airlift/compress/"):
                continue
            relative = name.removeprefix("io/airlift/compress/")
            if "/" in relative and not relative.startswith("zstd/"):
                continue
            data = source.read(name)
            if name.endswith(".class") and int.from_bytes(data[6:8], "big") > 52:
                raise ValueError("Portable Zstd decoder requires a newer Java runtime")
            if name in members:
                raise ValueError("Portable Zstd decoder class conflicts with existing dependencies")
            members[name] = data
    members["META-INF/licenses/aircompressor-0.27-Apache-2.0.txt"] = notice.read_bytes()
    members["META-INF/licenses/aircompressor-source.txt"] = (
        b"Airlift Aircompressor 0.27; unmodified Java Zstandard and shared API classes.\n"
        b"Source: https://github.com/airlift/aircompressor/tree/0.27\n")
    pending = dependencies.with_name(dependencies.name + ".pending")
    with zipfile.ZipFile(pending, "w") as target:
        for name, data in sorted(members.items()):
            put_member(target, name, data)
    pending.replace(dependencies)
    return {"sha256": sha256(decoder), "implementation": "Java Zstandard 0.27", "iosRuntimeVerified": False}


def build_host(dependencies: Path, output: Path, work: Path, javac: str | None = None) -> dict:
    compiler = javac or shutil.which("javac")
    if not compiler:
        raise ValueError("A JDK compiler with --release support is required")
    java_root = Path(__file__).resolve().parent / "java"
    sources = sorted(java_root.rglob("*.java"))
    sources += sorted((java_root.parent / "dex-compat/java").rglob("*.java"))
    snapshot = work / "host-source"
    frozen_sources = []
    fingerprint = hashlib.sha256()
    source_pin = json.loads((java_root.parent / "upstream.json").read_text())["reviewedAndroidSources"]
    derived_pin = json.loads((java_root.parent / "upstream.json").read_text())["derivedAndroidSources"]
    for item in source_pin["files"]:
        if sha256(java_root.parent / item["path"]) != item["sha256"]:
            raise ValueError("Reviewed Android source checksum mismatch: " + item["path"])
    for path in sources:
        relative = path.relative_to(java_root.parent)
        data = path.read_bytes()
        fingerprint.update(relative.as_posix().encode())
        fingerprint.update(data)
        destination = snapshot / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        frozen_sources.append(destination)
    classes = work / "host-classes"
    classes.mkdir(parents=True, exist_ok=True)
    subprocess.run([compiler, "--release", "8", "-Xlint:-options", "-cp", str(dependencies),
                    "-d", str(classes), *(str(path) for path in frozen_sources)], check=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w") as target:
        for path in sorted(classes.rglob("*.class")):
            data = path.read_bytes()
            if data[:4] != b"\xca\xfe\xba\xbe" or struct.unpack_from(">H", data, 6)[0] != 52:
                raise ValueError("Host compiler did not emit Java 8 bytecode")
            put_member(target, path.relative_to(classes).as_posix(), data)
        put_member(target, "META-INF/licenses/reviewed-android-sources.json",
                   json.dumps(source_pin, sort_keys=True, indent=2).encode("utf-8"))
        for item in source_pin["files"]:
            put_member(target, "META-INF/source/" + item["upstreamPath"],
                       (snapshot / item["path"]).read_bytes())
        put_member(target, "META-INF/licenses/derived-android-sources.json",
                   json.dumps(derived_pin, sort_keys=True, indent=2).encode("utf-8"))
        for item in derived_pin["files"]:
            put_member(target, "META-INF/source/" + item["upstreamPath"],
                       (snapshot / item["path"]).read_bytes())
    return {"sha256": sha256(output), "sourceSha256": fingerprint.hexdigest(),
            "sourceFiles": len(sources), "entrypoint": "dev.tachibooks.engine.ExtensionHost.invoke",
            "jniSignature": "(Ljava/lang/String;)Ljava/lang/String;"}
