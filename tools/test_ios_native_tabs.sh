#!/usr/bin/env bash
# Run the hosted UIKit/Flutter integration smoke on an available iOS 27 iPhone.
# Requires macOS/Xcode; the xcresult contains native test diagnostics.
set -euo pipefail
export FLUTTER_SWIFT_PACKAGE_MANAGER=false

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'Native tab tests require macOS with Xcode and an iOS 27 simulator.' >&2
  exit 1
fi
for tachi_command in flutter xcodebuild xcrun pod python3; do
  if ! command -v "$tachi_command" >/dev/null 2>&1; then
    printf 'Required command is missing: %s\n' "$tachi_command" >&2
    exit 1
  fi
done

tachi_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$tachi_root"
mkdir -p artifacts
tachi_result="$tachi_root/artifacts/native-tabs-smoke.xcresult"
if [[ -e "$tachi_result" ]]; then
  printf 'Previous test result exists; preserve or remove it before rerunning: %s\n' "$tachi_result" >&2
  exit 1
fi

xcodebuild -version
xcrun --sdk iphonesimulator --show-sdk-version
# Discover actual runtime/device identifiers; never guess a model or UUID.
# Match the user's iPhone 15 Pro Max and iOS major version.
tachi_simulator="$(python3 - "$tachi_root/artifacts/native-tabs-simulator.json" <<'PY'
import json
import subprocess
import sys

inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '--json'], text=True))
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip()
if sdk.split('.')[0] != '27':
    raise SystemExit(f'Expected iOS 27 SDK, selected {sdk}; review Xcode selection.')
runtimes = {
    runtime['identifier']: runtime
    for runtime in inventory.get('runtimes', [])
    if runtime.get('isAvailable')
    and '.iOS-' in runtime['identifier']
    and runtime.get('version', '').split('.')[0] == '27'
}
device_types = {
    item['identifier']: item for item in inventory.get('devicetypes', [])
}
target_name = 'iPhone 15 Pro Max'
candidates = []
for runtime_id, devices in inventory.get('devices', {}).items():
    runtime = runtimes.get(runtime_id)
    if runtime is None:
        continue
    for device in devices:
        kind = device_types.get(device.get('deviceTypeIdentifier'), {})
        if device.get('isAvailable') and kind.get('name') == target_name:
            version = tuple(int(part) for part in runtime['version'].split('.'))
            sdk_version = tuple(int(part) for part in sdk.split('.'))
            rank = (version[:2] == sdk_version[:2], device.get('state') == 'Booted', version, device['name'])
            candidates.append((rank, runtime, device))
if not candidates:
    target_types = [item for item in device_types.values() if item.get('name') == target_name]
    compatible = []
    for runtime in runtimes.values():
        supported = {item['identifier'] for item in runtime.get('supportedDeviceTypes', [])}
        for kind in target_types:
            if kind['identifier'] in supported:
                version = tuple(int(part) for part in runtime['version'].split('.'))
                rank = (version[:2] == tuple(int(part) for part in sdk.split('.'))[:2], version)
                compatible.append((rank, runtime, kind))
    if not compatible:
        raise SystemExit('iPhone 15 Pro Max is unavailable for iOS 27; install its simulator device type/runtime. No fallback to iPhone Air.')
    _, runtime, kind = max(compatible, key=lambda item: item[0])
    udid = subprocess.check_output(['xcrun', 'simctl', 'create', target_name, kind['identifier'], runtime['identifier']], text=True, timeout=60).strip()
    if not udid:
        raise SystemExit('Could not create the iPhone 15 Pro Max simulator.')
    device = {'name': target_name, 'udid': udid, 'state': 'Shutdown', 'isAvailable': True, 'deviceTypeIdentifier': kind['identifier']}
    candidates.append(((), runtime, device))
_, runtime, device = max(candidates, key=lambda item: item[0])
with open(sys.argv[1], 'w', encoding='utf-8') as handle:
    json.dump({'sdkVersion': sdk, 'runtime': runtime, 'device': device}, handle, indent=2)
    handle.write('\n')
print(f"Selected {device['name']} / {runtime['name']} / {device['udid']}", file=sys.stderr)
print(device['udid'])
PY
)"

# simctl's bootstatus can otherwise wait indefinitely on an unhealthy runtime.
python3 - "$tachi_simulator" <<'PY'
import json
import subprocess
import sys

udid = sys.argv[1]
try:
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json'], text=True))
    device = next(item for group in devices['devices'].values() for item in group if item['udid'] == udid)
    if device['state'] != 'Booted':
        subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True, timeout=60)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True, timeout=180)
except subprocess.TimeoutExpired as error:
    raise SystemExit(f'Simulator boot exceeded its bounded timeout: {error.cmd}')
PY

# Generate Flutter's Xcode configuration and install Pods. The hosted XCTest
# below builds the simulator app itself; a full Flutter build here would
# compile the same native dependencies into a second products directory.
printf '%s\n' '::group::Prepare Flutter simulator configuration and Pods'
tachi_prepare_started=$SECONDS
flutter pub get --enforce-lockfile
flutter build ios --simulator --debug --no-pub --config-only \
  2>&1 | tee "$tachi_root/artifacts/native-tabs-compile.log"
printf 'Simulator configuration prepared in %ss.\n' "$((SECONDS - tachi_prepare_started))"
printf '%s\n' '::endgroup::'
printf '%s\n' '::group::Build simulator app once and run hosted native tests'
tachi_tests_started=$SECONDS
xcodebuild -quiet test \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$tachi_simulator" \
  -destination-timeout 60 \
  -only-testing:RunnerTests \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -resultBundlePath "$tachi_result" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$tachi_root/artifacts/native-tabs-smoke.log"
printf 'Native build and tests completed in %ss.\n' "$((SECONDS - tachi_tests_started))"
printf '%s\n' '::endgroup::'

# Best-effort visual reference of the real running app, rather than a renderer
# mock. The XCTest result remains the behavior evidence; this PNG needs review.
if xcrun simctl launch "$tachi_simulator" dev.tachibooks.tachiBooks; then
  python3 - <<'PY'
import time
time.sleep(5)
PY
  xcrun simctl io "$tachi_simulator" screenshot "$tachi_root/artifacts/native-tabs-simulator.png" \
    || printf '%s\n' 'Optional simulator screenshot could not be captured.' >&2
fi

printf 'Native six-tab smoke passed. XCTest result: %s\n' "$tachi_result"
printf '%s\n' 'Simulator results do not confirm a pixel match or physical iPhone/iPad behavior.'
