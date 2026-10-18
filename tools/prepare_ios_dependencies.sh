#!/usr/bin/env bash
# Integrate CocoaPods/Flutter before fingerprinting the Xcode project.
# This prepares configuration only; it does not boot or compile a simulator.
set -euo pipefail
export FLUTTER_SWIFT_PACKAGE_MANAGER=false

if [[ $# -ne 0 ]]; then
  printf '%s\n' 'Usage: bash tools/prepare_ios_dependencies.sh' >&2
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'Preparing iOS dependencies requires macOS with Xcode.' >&2
  exit 1
fi
for tachi_command in flutter pod python3; do
  if ! command -v "$tachi_command" >/dev/null 2>&1; then
    printf 'Required command is missing: %s\n' "$tachi_command" >&2
    exit 1
  fi
done
tachi_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$tachi_root"
mkdir -p artifacts

# Quick preflight must have generated Flutter's configuration with the pinned
# pub lock before CocoaPods reads it. The engine must also be prepared first.
if [[ ! -f ios/Flutter/Generated.xcconfig ]]; then
  printf '%s\n' 'Run the quick iOS preflight before preparing Pods.' >&2
  exit 1
fi
if [[ ! -f packages/tachi_runtime/ios/Runtime/include/jni.h ]]; then
  printf '%s\n' 'Prepare the verified extension engine before installing Pods.' >&2
  exit 1
fi

printf '%s\n' '::group::Prepare Flutter configuration and CocoaPods integration'
# Resolve Pods explicitly, preserving its progress in a dedicated raw log.
python3 tools/run_build_phase.py --name native-pods-install --timeout 600 \
  --log "$tachi_root/artifacts/native-pods-install.log" \
  --status "$tachi_root/artifacts/native-pods-install.status.json" \
  -- pod install --project-directory=ios --verbose
# The config-only command applies Flutter migrations and uses installed Pods;
# the later XCTest build compiles native dependencies once.
python3 tools/run_build_phase.py --name native-pods-configuration --timeout 240 \
  --log "$tachi_root/artifacts/native-tabs-compile.log" \
  --status "$tachi_root/artifacts/native-pods-configuration.status.json" \
  -- flutter build ios --simulator --debug --no-pub --config-only
python3 - <<'PY'
from pathlib import Path

lock = Path('ios/Podfile.lock')
manifest = Path('ios/Pods/Manifest.lock')
if not lock.is_file() or not manifest.is_file() or lock.read_bytes() != manifest.read_bytes():
    raise SystemExit('CocoaPods lock and installed manifest do not match; dependency setup is incomplete.')
print('CocoaPods integration and Flutter configuration prepared before source fingerprinting.')
PY
printf '%s\n' '::endgroup::'
