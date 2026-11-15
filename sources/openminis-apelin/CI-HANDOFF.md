# Independent CI handoff

The user authorized importing this source into the existing public repository
`Huayuarc/shuangye.github.io` on `main` and a normal push to start its independent
`.github/workflows/build-openminis-apelin.yml`. Existing Theos/APT workflows are
not build entry points for this host.

## Provenance and archive verification

All 5920 file sizes and SHA256 values in `ci-source-manifest.json` were verified
against the received archive before integration edits. That manifest remains the
original archive inventory, not a claim that integration edits have identical
hashes. Local LAME `.o` and `.lo` leftovers are excluded from publication.
Vendored upstream binary test fixtures and documented Android proot loader
resources are retained for their original purposes, never copied as an iOS app
or represented as newly compiled artifacts. Licenses and notices are preserved.

The archive cannot encode Git index gitlinks, and the available repository tools
do not create them. `scripts/ci_fetch_dependencies.py` therefore checks out:

- `deps/ish`: `0fd17a135e78b7a0cf08a4f5831217bbb76ed22f`
- `deps/proot`: `8b31a69345730692f2f49a88694fdcaec78b2031`

URLs are checked against `.gitmodules`; each checkout is detached at the manifest
SHA, verified, then recursively initialized from its own gitlinks. Branch heads
are never build inputs. Run this helper only in a fresh checkout; it refuses to
overwrite existing dependency directories.

## Build and diagnostics

GitHub's `macos-26` image provides `/Applications/Xcode_26.2.app`; the workflow
selects that real installation and records architecture, Xcode, Swift and SDK.
It installs `ninja llvm lld libarchive pkg-config meson` with Homebrew and pins
Go 1.25.5 using `actions/setup-go@v6` and `GOTOOLCHAIN`, matching rclone-mobile's
go.mod. Run 43695887872 failed in the pinned experimental JSON module's alias
bridge with `undefined: json.SkipFunc`; Go 1.25.5's JSON v2 source provides that
API. Run 43696702961 confirmed the fix with a successful complete unsigned
build at commit bf24258847ed6406d78107049dd882a9d1a151c6. Go version and
experiment selection are retained in diagnostics. CI adds `lld`'s bin directory
to PATH for the iSH ARM64 ELF VDSO linker, then runs
`bash scripts/ci_build_openminis.sh` from this directory. The script checks SDK
26.2+ and Swift 6.1+, verifies generated skills and Swift policy, prepares native
dependencies, resolves Swift packages and compiles the complete Minis scheme in
Release with signing disabled and deployment target 16.0.

The workflow always uploads available environment/dependency/build logs and the
Xcode result bundle. If a dependency fails before Xcode build, no xcresult exists;
the dependency log is the evidence. No app, IPA or DEB is published. A successful
unsigned compile does not prove iOS 16.1.2 runtime compatibility or produce a
release. Source/API compatibility changes must be coordinated with the source
project; native backend, signing and dual-bootstrap packages remain separate work.

`_config.yml` excludes `sources/` from the Jekyll site. The public Git repository
still exposes the source itself, as authorized. CI has only `contents: read` and
does not commit artifacts or trigger APT publication.
