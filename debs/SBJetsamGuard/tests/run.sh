#!/bin/sh
# Portable host-only regression; all outputs are temporary and auto-removed.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/sjg-tests.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
CC=${CC:-cc}
FLAGS='-std=c11 -O2 -Wall -Wextra -Werror'
"$CC" $FLAGS ${CFLAGS:-} "$HERE/policy_test.c" -o "$BUILD/policy_test"
"$CC" $FLAGS ${CFLAGS:-} -I"$HERE/stubs" "$HERE/main_mock_test.c" -o "$BUILD/main_mock_test"
"$BUILD/policy_test"
"$BUILD/main_mock_test"
