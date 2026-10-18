#!/usr/bin/env bash
# Run the hosted UIKit/Flutter integration smoke on an available iOS 27 iPhone.
# Requires macOS/Xcode; the xcresult contains native test diagnostics.
set -euo pipefail
export FLUTTER_SWIFT_PACKAGE_MANAGER=false

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != '--select-only' ) ]]; then
  printf '%s\n' 'Usage: bash tools/test_ios_native_tabs.sh [--select-only]' >&2
  exit 2
fi
tachi_select_only=false
if [[ "${1:-}" == '--select-only' ]]; then tachi_select_only=true; fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'Native tab tests require macOS with Xcode and an iOS 27 simulator.' >&2
  exit 1
fi
tachi_commands=(xcodebuild xcrun python3)
if [[ "$tachi_select_only" == false ]]; then tachi_commands+=(flutter pod); fi
for tachi_command in "${tachi_commands[@]}"; do
  if ! command -v "$tachi_command" >/dev/null 2>&1; then
    printf 'Required command is missing: %s\n' "$tachi_command" >&2
    exit 1
  fi
done

tachi_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$tachi_root"
mkdir -p artifacts
tachi_result="$tachi_root/artifacts/native-tabs-smoke.xcresult"
if [[ "$tachi_select_only" == false && -e "$tachi_result" ]]; then
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

inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '--json'], text=True, timeout=30))
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True, timeout=30).strip()
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
if [[ "$tachi_select_only" == true ]]; then
  printf '%s\n' 'Required iPhone 15 Pro Max / iOS 27 simulator selected before build setup.'
  exit 0
fi

# CI has already integrated dependencies before issuing its full receipt.
# A standalone invocation prepares the same project before checking it.
tachi_preflight_receipt="${TACHI_PREFLIGHT_RECEIPT:-$tachi_root/artifacts/ios-preflight.json}"
if [[ -n "${TACHI_PREFLIGHT_RECEIPT:-}" ]]; then
  python3 tools/ios_build_preflight.py --verify --receipt "$tachi_preflight_receipt"
else
  python3 tools/ios_build_preflight.py --quick --receipt "$tachi_preflight_receipt"
  bash tools/prepare_ios_dependencies.sh
  python3 tools/ios_build_preflight.py --receipt "$tachi_preflight_receipt"
fi
# Boot only after dependency resolution, so a cold simulator does not compete
# with Flutter/CocoaPods setup for CPU and disk on the hosted runner.
python3 - "$tachi_simulator" <<'PY'
import json
import subprocess
import sys

udid = sys.argv[1]
try:
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json'], text=True, timeout=30))
    device = next(item for group in devices['devices'].values() for item in group if item['udid'] == udid)
    if device['state'] != 'Booted':
        subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True, timeout=60)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True, timeout=180)
except subprocess.TimeoutExpired as error:
    raise SystemExit(f'Simulator boot exceeded its bounded timeout: {error.cmd}')
PY
printf '%s\n' '::group::Compile simulator app and test bundle once'
tachi_xcode_flags=(
  -workspace ios/Runner.xcworkspace
  -scheme Runner
  -configuration Debug
  -derivedDataPath "$tachi_root/build/ios/native-smoke"
  -destination "platform=iOS Simulator,id=$tachi_simulator"
  -destination-timeout 60
  -only-testing:RunnerTests
  -parallel-testing-enabled NO
  -maximum-concurrent-test-simulator-destinations 1
  ONLY_ACTIVE_ARCH=YES
  CODE_SIGNING_ALLOWED=NO
)
# Keep compiler output in the file so an idle watchdog can distinguish a
# working compiler from a silent hang. -quiet would hide that progress.
python3 tools/run_build_phase.py --name native-simulator-build \
  --timeout 1500 --idle-timeout 300 \
  --log "$tachi_root/artifacts/native-tabs-build.log" \
  --status "$tachi_root/artifacts/native-simulator-build.status.json" \
  -- xcodebuild build-for-testing "${tachi_xcode_flags[@]}"
printf '%s\n' '::endgroup::'
printf '%s\n' '::group::Run hosted native tests without rebuilding'
python3 tools/run_build_phase.py --name native-simulator-tests --timeout 300 \
  --log "$tachi_root/artifacts/native-tabs-smoke.log" \
  --status "$tachi_root/artifacts/native-simulator-tests.status.json" \
  -- xcodebuild test-without-building "${tachi_xcode_flags[@]}" \
  -resultBundlePath "$tachi_result"
printf '%s\n' '::endgroup::'

# Best-effort visual reference of the real running app, rather than a renderer
# mock. The XCTest result remains the behavior evidence; this PNG needs review.
python3 - "$tachi_simulator" "$tachi_root/artifacts/native-tabs-simulator.png" <<'PY'
import subprocess
import sys
import time

try:
    subprocess.run(['xcrun', 'simctl', 'launch', sys.argv[1], 'dev.tachibooks.tachiBooks'], check=True, timeout=30)
    time.sleep(5)
    subprocess.run(['xcrun', 'simctl', 'io', sys.argv[1], 'screenshot', sys.argv[2]], check=True, timeout=30)
except (subprocess.SubprocessError, OSError):
    print('Optional simulator screenshot could not be captured.', file=sys.stderr)
PY

printf 'Native six-tab smoke passed. XCTest result: %s\n' "$tachi_result"
printf '%s\n' 'Simulator results do not confirm a pixel match or physical iPhone/iPad behavior.'
