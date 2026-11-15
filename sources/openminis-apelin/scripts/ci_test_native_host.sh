#!/bin/bash
# Run only the native-development host XCTest class on an isolated simulator.
set -Eeuo pipefail
trap 'rc=$?; printf "error: host XCTest command failed (exit %s, line %s): %s\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2; exit "$rc"' ERR
cd "$(dirname "$0")/.."
: "${RUNNER_TEMP:?}"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]]
out="${RUNNER_TEMP:?}/openminis-host-diagnostics"
mkdir -p "$out"
test -f src/ios/MinisTests/MinisNativeDevelopmentHostTests.swift
python3 scripts/ios-unit-tests/static_check.py
python3 scripts/generate_apelin_skills.py --check
python3 scripts/check_development_policy.py
# Enumerate installed runtimes first; never silently skip an unavailable runtime.
xcrun simctl list --json > "$out/simulators.json"
python3 - "$out/simulators.json" > "$out/runtime.txt" <<'PY'
import json, sys
runtimes = [r for r in json.load(open(sys.argv[1]))['runtimes']
            if r.get('isAvailable') and r.get('platform') == 'iOS']
# Some simctl versions omit platform and expose only the runtime identifier.
if not runtimes:
    runtimes = [r for r in json.load(open(sys.argv[1]))['runtimes']
                if r.get('isAvailable') and '.SimRuntime.iOS-' in r.get('identifier', '')]
if not runtimes:
    raise SystemExit('error: no installed available iOS simulator runtime')
runtimes.sort(key=lambda r: tuple(int(p) for p in r['version'].split('.')), reverse=True)
print(runtimes[0]['identifier'])
PY
# Create our own simulator so host installation cannot touch an existing container.
udid=$(xcrun simctl create "OpenMinis-native-${GITHUB_RUN_ID:-local}" \
    com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$(cat "$out/runtime.txt")")
trap 'xcrun simctl shutdown "${udid:?}" >/dev/null 2>&1 || true; xcrun simctl delete "${udid:?}" >/dev/null 2>&1 || true' EXIT
printf '%s\n' "$udid" > "$out/simulator-udid.txt"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
if [[ ! -f src/ios/Configs/ProviderCustomization.xcconfig ]]; then
    cp src/ios/Configs/ProviderCustomization.xcconfig.example src/ios/Configs/ProviderCustomization.xcconfig
fi
bash deps/build_lame.sh --simulator
bash deps/build_ffmpeg.sh --simulator
bash deps/build_ish.sh release --simulator
bash deps/prepare_alpine_rootfs.sh
bash deps/build_rclone_ios.sh
common=(-project src/ios/Minis.xcodeproj -configuration Debug
    -destination "platform=iOS Simulator,id=$udid"
    -derivedDataPath "${RUNNER_TEMP:?}/openminis-host-derived"
    -clonedSourcePackagesDirPath "${RUNNER_TEMP:?}/openminis-host-packages")
# The test bundle embeds Minis.debug.dylib, but Minis.app is never launched.
xcodebuild build -scheme Minis "${common[@]}" CODE_SIGNING_ALLOWED=NO \
    IPHONEOS_DEPLOYMENT_TARGET=16.0 2>&1 | tee "$out/build-app.log"
xcodebuild build-for-testing -scheme MinisUnitTests "${common[@]}" \
    -only-testing:MinisTests/MinisNativeDevelopmentHostTests CODE_SIGNING_ALLOWED=NO \
    IPHONEOS_DEPLOYMENT_TARGET=16.0 2>&1 | tee "$out/build-tests.log"
python3 - "${RUNNER_TEMP:?}/openminis-host-derived/Build/Products" <<'PY'
import pathlib, plistlib, sys
products = pathlib.Path(sys.argv[1])
host = products / 'Debug-iphonesimulator/MinisTestHost.app/Info.plist'
if plistlib.loads(host.read_bytes()).get('CFBundleIdentifier') != 'com.openminis.MinisTestHost':
    raise SystemExit('error: unexpected test host bundle identifier')
runs = list(products.glob('*.xctestrun'))
if len(runs) != 1:
    raise SystemExit('error: expected exactly one xctestrun')
data = plistlib.loads(runs[0].read_bytes())
hosts = []
def check(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == 'TestHostBundleIdentifier': hosts.append(child)
            if key in ('TestHostPath', 'UITargetAppPath') and isinstance(child, str):
                if '/Minis.app' in child or 'com.openminis.app' in child:
                    raise SystemExit('error: xctestrun would launch the real app')
            check(child)
    elif isinstance(value, list):
        for child in value: check(child)
check(data)
if hosts != ['com.openminis.MinisTestHost']:
    raise SystemExit('error: xctestrun must contain only MinisTestHost')
PY
# Do not use continue-on-error: preserve xcodebuild failure and the xcresult.
xcodebuild test-without-building -scheme MinisUnitTests "${common[@]}" \
    -only-testing:MinisTests/MinisNativeDevelopmentHostTests -parallel-testing-enabled NO \
    -resultBundlePath "${RUNNER_TEMP:?}/openminis-host-tests.xcresult" \
    CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=16.0 2>&1 | tee "$out/test.log"
xcrun xcresulttool get test-results tests \
    --path "${RUNNER_TEMP:?}/openminis-host-tests.xcresult" --format json > "$out/test-results.json"
python3 scripts/ci_verify_host_xctest.py "$out/test-results.json" \
    src/ios/MinisTests/MinisNativeDevelopmentHostTests.swift | tee "$out/verification.log"
