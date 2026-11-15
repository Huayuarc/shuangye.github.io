#!/usr/bin/env bash
# Build apelin-disassembler and apelin-assembler for iPhoneOS arm64 and
# package each as a roothide and a rootless .deb, verified.
#
#   Scripts/build-agent-tools.sh [output-directory]
#
# Output defaults to build/Packages under this folder. SCRATCH_PATH (default
# /private/tmp/apelin-agent-tools-spm) holds SwiftPM's build; spelled
# /private/tmp, never /tmp, so prefix maps match what the compiler sees.
# CONFIGURATION=Debug keeps symbols and source paths for a device test.

set -Eeuo pipefail

extension_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
repository_root="$(cd -- "$extension_root/../../.." && pwd -P)"
output_directory="${1:-$extension_root/build/Packages}"
scratch_path="${SCRATCH_PATH:-/private/tmp/apelin-agent-tools-spm}"
configuration="${CONFIGURATION:-Release}"
deployment_target=16.0

for required in dpkg-deb ldid; do
    command -v "$required" >/dev/null || {
        echo "error: $required is required (install it with your preferred package manager)" >&2
        exit 69
    }
done

sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
case "$configuration" in
Release) swift_configuration=release ;;
Debug) swift_configuration=debug ;;
*) echo "error: CONFIGURATION must be Release or Debug, not $configuration" >&2; exit 64 ;;
esac

# No build path may survive into a shipped binary: Swift's #file and
# debug info, and Capstone's and Keystone's C/C++ __FILE__, all map the
# repository and the scratch directory away.
prefix_maps=()
for private_path in "$repository_root" "$scratch_path"; do
    prefix_maps+=(-Xswiftc -file-prefix-map -Xswiftc "$private_path=.")
    prefix_maps+=(-Xcc "-ffile-prefix-map=$private_path=.")
    prefix_maps+=(-Xcxx "-ffile-prefix-map=$private_path=.")
done

swift_args=(
    --package-path "$extension_root"
    --scratch-path "$scratch_path"
    --configuration "$swift_configuration"
    --sdk "$sdk"
    --triple "arm64-apple-ios$deployment_target"
)
for product in apelin-disassembler apelin-assembler; do
    swift build "${swift_args[@]}" --product "$product" "${prefix_maps[@]}"
done

binaries="$(swift build "${swift_args[@]}" --show-bin-path)"

# The corresponding-source archive is made once per run, for both flavors
# of the assembler; an older one would describe other bytes.
mkdir -p "$output_directory"
rm -f "$output_directory"/wiki.qaq.apelin.agent-tools.*_source.tar.xz

for flavor in roothide rootless; do
    for tool in disassembler assembler; do
        CONFIGURATION="$configuration" CHECKOUTS="$scratch_path/checkouts" \
            "$extension_root/Scripts/package-agent-tool.sh" "$tool" "$binaries/apelin-$tool" "$flavor" "$output_directory"
    done
done
