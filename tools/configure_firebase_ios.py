"""Install a supplied, matching Firebase iOS plist without printing its contents.

Run before building: python3 tools/configure_firebase_ios.py --config /path/to/plist
Input bytes remain unchanged. The helper changes only the destination iOS project.
"""

import argparse
import base64
import binascii
import os
from pathlib import Path
import plistlib
import re
import tempfile

BUNDLE_ID = "dev.tachibooks.tachiBooks"
RESOURCE_ID = "FB2E415253BACDF102593FDB"
REFERENCE_ID = "FB2E415253BACDF102593FDC"
CONFIG_NAME = "GoogleService-Info.plist"


def atomic_write(path: Path, data: bytes) -> None:
    handle, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def configure(config_path: Path, ios_dir: Path) -> None:
    # Prepare and validate every edit before changing any destination file.
    config_bytes = config_path.read_bytes()
    config = plistlib.loads(config_bytes)
    required = ["BUNDLE_ID", "GOOGLE_APP_ID", "PROJECT_ID", "API_KEY", "CLIENT_ID", "REVERSED_CLIENT_ID"]
    if not isinstance(config, dict) or any(not isinstance(config.get(key), str) or not config[key].strip() for key in required):
        raise ValueError("Firebase iOS config is missing required keys. No files changed.")
    if config["BUNDLE_ID"] != BUNDLE_ID:
        raise ValueError("Firebase iOS config has the wrong bundle ID for TachiBooks. No files changed.")
    if not re.fullmatch(r"[A-Za-z0-9.-]+\.apps\.googleusercontent\.com", config["CLIENT_ID"]):
        raise ValueError("Firebase config has an invalid Google iOS client ID. No files changed.")
    if config["REVERSED_CLIENT_ID"] != ".".join(reversed(config["CLIENT_ID"].split("."))):
        raise ValueError("Firebase config has an inconsistent Google callback scheme. No files changed.")

    info_path = ios_dir / "Runner" / "Info.plist"
    project_path = ios_dir / "Runner.xcodeproj" / "project.pbxproj"
    info = plistlib.loads(info_path.read_bytes())
    project = project_path.read_text(encoding="utf-8")
    bundle_ids = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);", project)
    runner_ids = {value.strip().strip('"') for value in bundle_ids if not value.strip().strip('"').endswith(".RunnerTests")}
    if runner_ids != {BUNDLE_ID}:
        raise ValueError("Xcode Runner bundle IDs do not match TachiBooks. No files changed.")
    if not isinstance(info, dict):
        raise ValueError("Runner Info.plist is invalid. No files changed.")
    url_types = info.get("CFBundleURLTypes", [])
    if not isinstance(url_types, list) or any(
        not isinstance(item, dict)
        or ("CFBundleURLSchemes" in item and (
            not isinstance(item["CFBundleURLSchemes"], list)
            or any(not isinstance(value, str) for value in item["CFBundleURLSchemes"])
        ))
        for item in url_types
    ):
        raise ValueError("Runner URL types are invalid. No files changed.")
    info["GIDClientID"] = config["CLIENT_ID"]
    urls = [item for item in url_types if item.get("CFBundleURLName") != "TachiBooks Google"]
    if not any(config["REVERSED_CLIENT_ID"] in item.get("CFBundleURLSchemes", []) for item in urls):
        urls.append({"CFBundleTypeRole": "Editor", "CFBundleURLName": "TachiBooks Google", "CFBundleURLSchemes": [config["REVERSED_CLIENT_ID"]]})
    info["CFBundleURLTypes"] = urls
    if CONFIG_NAME not in project:
        for marker in ["/* End PBXBuildFile section */", "/* End PBXFileReference section */"]:
            if project.count(marker) != 1:
                raise ValueError("Unsupported Xcode project structure. No files changed.")
        project = project.replace("/* End PBXBuildFile section */",
            f"\t\t{RESOURCE_ID} /* {CONFIG_NAME} in Resources */ = {{isa = PBXBuildFile; fileRef = {REFERENCE_ID} /* {CONFIG_NAME} */; }};\n/* End PBXBuildFile section */")
        project = project.replace("/* End PBXFileReference section */",
            f'\t\t{REFERENCE_ID} /* {CONFIG_NAME} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "{CONFIG_NAME}"; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
        group_pattern = r"(97C146F01CF9000F007C117D /\* Runner \*/ = \{\s*isa = PBXGroup;\s*children = \()"
        resources_pattern = r"(97C146EC1CF9000F007C117D /\* Resources \*/ = \{\s*isa = PBXResourcesBuildPhase;\s*buildActionMask = \d+;\s*files = \()"
        project, groups = re.subn(group_pattern, rf"\1\n\t\t\t\t{REFERENCE_ID} /* {CONFIG_NAME} */,", project)
        project, phases = re.subn(resources_pattern, rf"\1\n\t\t\t\t{RESOURCE_ID} /* {CONFIG_NAME} in Resources */,", project)
        if groups != 1 or phases != 1:
            raise ValueError("Unsupported Xcode Runner resource structure. No files changed.")
    elif not all(identifier in project for identifier in [RESOURCE_ID, REFERENCE_ID]):
        raise ValueError("Firebase resources were configured another way. Review Xcode resources manually. No files changed.")

    # Presence in a comment/file reference alone does not put the plist into the
    # Runner bundle. Validate both links on every run, including reconfiguration.
    group = re.search(r"97C146F01CF9000F007C117D /\* Runner \*/ = \{.*?children = \((.*?)\);", project, re.DOTALL)
    resources = re.search(r"97C146EC1CF9000F007C117D /\* Resources \*/ = \{.*?files = \((.*?)\);", project, re.DOTALL)
    if (group is None or resources is None
        or group.group(1).count(REFERENCE_ID) != 1
        or resources.group(1).count(RESOURCE_ID) != 1
        or len(re.findall(rf"{REFERENCE_ID} /\* {re.escape(CONFIG_NAME)} \*/ =", project)) != 1
        or len(re.findall(rf"{RESOURCE_ID} /\* {re.escape(CONFIG_NAME)} in Resources \*/ =", project)) != 1):
        raise ValueError("Firebase plist is not linked exactly once into Runner resources. No files changed.")

    destination = ios_dir / "Runner" / CONFIG_NAME
    atomic_write(destination, config_bytes)
    atomic_write(info_path, plistlib.dumps(info, sort_keys=False))
    atomic_write(project_path, project.encode("utf-8"))


def main() -> None:
    parser = argparse.ArgumentParser(description="Configure TachiBooks Firebase iOS without exposing config values.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--config", type=Path)
    source.add_argument("--config-env", action="store_true",
                        help="Read TACHI_GOOGLE_SERVICE_INFO_PLIST_BASE64 without printing it")
    parser.add_argument("--ios-dir", type=Path, default=Path(__file__).resolve().parent.parent / "ios")
    args = parser.parse_args()
    try:
        if args.config_env:
            encoded = os.environ.get("TACHI_GOOGLE_SERVICE_INFO_PLIST_BASE64", "")
            if not encoded or len(encoded) > 90_000:
                raise ValueError("Missing or oversized Firebase config")
            payload = base64.b64decode(encoded, validate=True)
            if len(payload) > 65_536:
                raise ValueError("Oversized Firebase config")
            with tempfile.TemporaryDirectory(prefix="tachibooks-firebase-") as temporary:
                config_path = Path(temporary) / CONFIG_NAME
                config_path.write_bytes(payload)
                configure(config_path, args.ios_dir.resolve())
        else:
            configure(args.config.resolve(), args.ios_dir.resolve())
    except (ValueError, OSError, plistlib.InvalidFileException, binascii.Error):
        raise SystemExit("Firebase iOS configuration was not installed. Check the matching TachiBooks plist and project structure.") from None
    print("TachiBooks Firebase iOS configuration installed. Config values were not printed.")


if __name__ == "__main__":
    main()
