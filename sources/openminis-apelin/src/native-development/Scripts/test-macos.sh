#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ] || ! command -v swift >/dev/null 2>&1 || ! command -v sw_vers >/dev/null 2>&1; then
    echo 'Requires macOS with Swift 5.9+ and CryptoKit (iOS Darwin is unsupported).' >&2
    exit 2
fi
swift build --product native-development-service
bin_dir="$(swift build --show-bin-path)"
: "${bin_dir:?}"
NATIVE_SERVICE_EXECUTABLE="${bin_dir:?}/native-development-service" swift test
