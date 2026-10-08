#!/usr/bin/env bash
# Build on macOS: bash tools/build_ios.sh [positive-build-number]
# Output: build/ios/ipa/TachiBooks-unsigned.ipa. Re-sign before installing.
set -euo pipefail

# Keep dependency integration reproducible without changing the user's Flutter
# configuration. Isar and flutter_tts in the lockfile use CocoaPods.
export FLUTTER_SWIFT_PACKAGE_MANAGER=false

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'iOS compilation requires macOS with Xcode. This script cannot produce an IPA on Windows or Linux.' >&2
  exit 1
fi
if [[ $# -gt 1 || ( $# -eq 1 && ! "$1" =~ ^[1-9][0-9]*$ ) ]]; then
  printf '%s\n' 'Usage: bash tools/build_ios.sh [positive-build-number]' >&2
  exit 2
fi
for tachi_command in flutter xcodebuild xcrun pod python3 ditto shasum codesign; do
  if ! command -v "$tachi_command" >/dev/null 2>&1; then
    printf 'Required command is missing: %s\n' "$tachi_command" >&2
    exit 1
  fi
done
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
pod --version

tachi_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$tachi_root"
mkdir -p build/ios/ipa
tachi_output="$tachi_root/build/ios/ipa"
flutter --version --machine > "$tachi_output/flutter-version.json"
python3 - "$tachi_output/flutter-version.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    version = json.load(handle)
if version.get('frameworkVersion') != '3.47.4' or version.get('frameworkRevision') != '9584c6713b324636289d067944a46fd6b49df14b':
    raise SystemExit('Use official Flutter 3.47.4 (9584c6713b324636289d067944a46fd6b49df14b) for this build.')
PY

# The lockfile pins the plugin versions whose iOS requirements were reviewed.
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
tachi_flags=(--release --no-codesign --no-pub)
if [[ $# -eq 1 ]]; then
  tachi_flags+=("--build-number=$1")
fi
flutter build ios "${tachi_flags[@]}"

tachi_app="$tachi_root/build/ios/iphoneos/Runner.app"
if [[ ! -d "$tachi_app" ]]; then
  printf 'Expected device app was not built: %s\n' "$tachi_app" >&2
  exit 1
fi
if codesign --display "$tachi_app" >/dev/null 2>&1; then
  printf '%s\n' 'Expected an unsigned Runner.app, but the app has a signature. Review the build settings before packaging.' >&2
  exit 1
fi
python3 - "$tachi_app" "$tachi_output" <<'PY'
import json
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
with (app / 'Info.plist').open('rb') as handle:
    info = plistlib.load(handle)
if 'iPhoneOS' not in info.get('CFBundleSupportedPlatforms', []):
    raise SystemExit('Expected an iOS device app, not a simulator app.')
if not {1, 2}.issubset(info.get('UIDeviceFamily', [])):
    raise SystemExit('The build must target both iPhone and iPad.')
architectures = subprocess.check_output(['xcrun', 'lipo', '-archs', str(app / info['CFBundleExecutable'])], text=True).strip().split()
if 'arm64' not in architectures:
    raise SystemExit('The device executable is missing arm64.')
with (output / 'flutter-version.json').open(encoding='utf-8') as handle:
    flutter_version = json.load(handle)
build_info = {
    'artifact': 'TachiBooks-unsigned.ipa',
    'signing': 'UNSIGNED - requires signing and provisioning before installation',
    'bundleIdentifier': info['CFBundleIdentifier'],
    'version': info['CFBundleShortVersionString'],
    'buildNumber': info['CFBundleVersion'],
    'minimumIOS': info['MinimumOSVersion'],
    'deviceFamily': info['UIDeviceFamily'],
    'architectures': architectures,
    'flutterVersion': flutter_version['frameworkVersion'],
    'flutterRevision': flutter_version['frameworkRevision'],
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'checks': 'Flutter analyze, Flutter tests, release device compilation and package checks passed.',
    'runtimeValidation': 'Not performed on an iPhone or iPad by this build script.',
}
with (output / 'TachiBooks-unsigned.build-info.json').open('w', encoding='utf-8') as handle:
    json.dump(build_info, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
PY

tachi_staging="$(mktemp -d "$tachi_root/build/ios/.ipa-packaging.XXXXXX")"
trap 'rm -rf -- "$tachi_staging"' EXIT
mkdir "$tachi_staging/Payload"
ditto "$tachi_app" "$tachi_staging/Payload/Runner.app"
tachi_ipa="$tachi_output/TachiBooks-unsigned.ipa"
ditto -c -k --keepParent "$tachi_staging/Payload" "$tachi_ipa"
python3 - "$tachi_ipa" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    if archive.testzip() is not None or 'Payload/Runner.app/Info.plist' not in archive.namelist():
        raise SystemExit('The packaged IPA is incomplete or failed its ZIP integrity check.')
PY
(
  cd "$tachi_output"
  shasum -a 256 TachiBooks-unsigned.ipa > TachiBooks-unsigned.ipa.sha256
)
printf '\nUnsigned IPA created: %s\n' "$tachi_ipa"
printf '%s\n' 'This package must be re-signed with valid provisioning before installation. Native iPhone/iPad behavior still requires device testing.'
