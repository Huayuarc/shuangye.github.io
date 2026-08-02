#!/bin/bash
#
# Kayoko package builder.
#
# Building and packaging are handled by Theos. Each scheme needs a separately
# compiled binary because install names and path bases differ between schemes.
#
# Usage:
#   ./build.sh roothide
#   ./build.sh rootless
#   ./build.sh rootful
#
# Optional environment overrides:
#   THEOS=/path/to/theos       # otherwise auto-detected
#
# Output debs land in ./packages/. The architecture suffix distinguishes variants.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# Keep common package-manager paths available in minimal shells.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# --- Resolve Theos -----------------------------------------------------------
if [[ -z "${THEOS:-}" || ! -d "${THEOS:-}" ]]; then
    for candidate in "${HOME}/theos" /opt/theos "${HOME}/theos-roothide"; do
        if [[ -d "$candidate" ]]; then
            THEOS="$candidate"
            break
        fi
    done
fi
if [[ -z "${THEOS:-}" || ! -d "$THEOS" ]]; then
    echo "error: no Theos install found; set THEOS to your Theos path" >&2
    exit 1
fi
export THEOS

MAKE_BIN="$(command -v gmake || command -v make)"
PACKAGE_ID="$(awk -F': ' '/^Package:/{print $2; exit}' "$ROOT/control")"

cleanup_build_artifacts() {
    echo ""
    echo "==> Cleaning build cache…"
    "$MAKE_BIN" clean >/dev/null 2>&1 || true

    while IFS= read -r -d '' cache_dir; do
        rm -rf "$cache_dir"
    done < <(find "$ROOT" -type d -name .theos -prune -print0)

    find "$ROOT" -type f \( \
        -name '.DS_Store' -o \
        -name '*.o' -o \
        -name '*.Td' -o \
        -name '*.stamp' -o \
        -name '*.xcuserstate' \
    \) -delete 2>/dev/null || true
}

# --- Build one scheme --------------------------------------------------------
# Theos writes the deb as <package>_<version>_<arch>.deb. The selected package
# scheme controls the installation layout; CPU architectures remain defined by
# the root Makefile.
# theos_scheme: value passed to THEOS_PACKAGE_SCHEME ("" for rootful)
build_one() {
    local label="$1"
    local theos_scheme="$2"

    echo ""
    echo "==> Building ${label} package (THEOS=${THEOS})…"

    THEOS_PACKAGE_SCHEME="$theos_scheme" "$MAKE_BIN" clean >/dev/null 2>&1 || true
    THEOS_PACKAGE_SCHEME="$theos_scheme" "$MAKE_BIN" package FINALPACKAGE=1
}

# --- Dispatch ----------------------------------------------------------------
scheme="${1:-}"
case "$scheme" in
    -h|--help|help)
        echo "Usage: ./build.sh [roothide|rootless|rootful]"
        exit 0
        ;;
    roothide|rootless|rootful) ;;
    *)
        echo "error: unknown scheme '$scheme'" >&2
        echo "Usage: ./build.sh [roothide|rootless|rootful]" >&2
        exit 1
        ;;
esac

trap cleanup_build_artifacts EXIT

case "$scheme" in
    roothide) build_one roothide roothide ;;
    rootless) build_one rootless rootless ;;
    rootful)  build_one rootful  ""       ;;
esac

echo ""
echo "==> Done. Packages in ./packages/:"
ls -1 "$ROOT/packages/${PACKAGE_ID}_"*.deb 2>/dev/null || true
