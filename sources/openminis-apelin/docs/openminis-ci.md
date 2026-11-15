# OpenMinis–Apelin CI

Authorized target: the existing public `Huayuarc/shuangye.github.io` repository,
`main`. Source lives in `sources/openminis-apelin`; the independent workflow is
`.github/workflows/build-openminis-apelin.yml`. The Theos workflow is unrelated.
The CI repository is maintained in its own Apelin workspace, `shuangye-ci`.

## Source handoff

`python3 scripts/export_openminis_ci_source.py` audits Git-indexed and nonignored
worktree source. `--output build/openminis-ci-source.tar.gz` additionally writes
an archive, refusing an existing output. The manifest records every source file's
SHA256 and both upstream gitlink revisions. Git history and local configurations
are not exported. The scanner is a pattern check, not a guarantee that every
possible credential is detectable; public diffs still require review.

The only digest exceptions are pinned upstream redaction tests and a 726-byte
upstream console package fixture. That fixture is test input, not this project's
build output. Source code under Markdown/Attachments is required host source.

The CI repository must initialize iSH and PRoot at the exact manifest commits and
recursively initialize their dependencies. If source is copied without gitlinks,
the workflow must explicitly clone and detach those repositories at these commits;
ordinary `git submodule update` in the parent alone cannot initialize them.
Exclude `sources/` from Jekyll publication.

## Compile gate

`scripts/ci_build_openminis.sh` requires macOS, Swift 6.1+ and iOS SDK 26.2+.
It checks generated skills, executes the production Swift policy truth table,
prepares LAME → FFmpeg → iSH/AOT → Alpine → Rclone, resolves Swift packages and
builds the complete Minis Release scheme without signing. Metal is required so
FFmpeg cannot silently omit its Metal filter. Provider customization uses the
public empty example; provider secrets are not needed for this gate.

The diagnostic build sets deployment to iOS 16.0 so unavailable APIs become
compiler findings. It preserves the app and scheme dependencies/extensions.
A successful build does not prove extension compatibility, iOS 16 execution,
sheet cancellation behavior or backend authorization. The upstream full XCTest
runner uses a signed iPad-on-Mac test host and is not invoked by this unsigned
compile gate. The standalone Swift policy check covers policy verdicts only.

## Release gate remains open

An independent native service, authenticated transport, dispatch authorization,
service identity, signing/entitlements and real external packaging entry point
are still missing. The diagnostic workflow must not publish an unsigned app as
a release or produce placeholder DEBs. Separate real rootless and roothide builds
and device checks are required after those parts exist. Permanent package/bundle
identifiers must be settled before the first installation. No release or runtime
success has yet been established.
