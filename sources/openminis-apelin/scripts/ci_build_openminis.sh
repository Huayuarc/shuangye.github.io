#!/bin/bash
# Compile the real host and its dependencies; this is not a release packager.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'A macOS runner with Xcode 26.2+ is required.' >&2
    exit 2
fi
: "${RUNNER_TEMP:?CI runner temporary directory is required}"
command -v meson >/dev/null
command -v ninja >/dev/null
command -v go >/dev/null
xcodebuild -version
xcrun swiftc --version
python3 - <<'PY'
import re, subprocess
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip()
version = tuple(map(int, sdk.split('.')[:2]))
if version < (26, 2):
    raise SystemExit('iOS SDK 26.2+ is required by current host source')
swift = subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True)
m = re.search(r'Swift version (\d+)\.(\d+)', swift)
if not m or tuple(map(int, m.groups())) < (6, 1):
    raise SystemExit('Swift 6.1+ is required')
PY
python3 scripts/generate_apelin_skills.py --check
python3 scripts/check_development_policy.py
# Dependencies are checked out by ci_fetch_dependencies.py at the manifest SHA.
# This archive import has no root gitlinks; never follow .gitmodules branches.
test -d deps/ish/.git
test -d deps/proot/.git
if [[ ! -f src/ios/Configs/ProviderCustomization.xcconfig ]]; then
    cp src/ios/Configs/ProviderCustomization.xcconfig.example src/ios/Configs/ProviderCustomization.xcconfig
fi
xcrun --sdk iphoneos metal --version
bash deps/build_lame.sh
bash deps/build_ffmpeg.sh
bash deps/build_ish.sh release
bash deps/prepare_alpine_rootfs.sh
bash deps/build_rclone_ios.sh
python3 scripts/check_apelin_build_environment.py
xcodebuild -resolvePackageDependencies -project src/ios/Minis.xcodeproj -scheme Minis \
    -clonedSourcePackagesDirPath "${RUNNER_TEMP:?}/openminis-packages"
# Preserve every scheme dependency/extension. Compiler availability errors fail CI.
xcodebuild build -project src/ios/Minis.xcodeproj -scheme Minis \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "${RUNNER_TEMP:?}/openminis-derived" \
    -clonedSourcePackagesDirPath "${RUNNER_TEMP:?}/openminis-packages" \
    -resultBundlePath "${RUNNER_TEMP:?}/openminis-build.xcresult" \
    CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=16.0
# This unsigned build is diagnostic only. No app/service/package is published.
