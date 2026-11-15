#!/bin/sh
# Package a verified unsigned OpenMinis IPA as the one Apelin-installable deb.
set -eu
: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
: "${APELIN_PREFIX?}"

input="${OPENMINIS_IPA:-${APELIN_PROJECT_ROOT}/sources/openminis-apelin/artifacts/Minis-unsigned.ipa}"
[ -f "$input" ] || {
  echo "OpenMinis IPA input is missing: $input" >&2
  echo "Place the CI artifact at sources/openminis-apelin/artifacts/Minis-unsigned.ipa" >&2
  exit 2
}

stage="$(mktemp -d "${TMPDIR:?}openminis-stage.XXXXXX")"
work="$(mktemp -d "${TMPDIR:?}openminis-work.XXXXXX")"
trap 'rm -rf -- "${stage:?}" "${work:?}"' EXIT

python3 - "$input" "$work/app" "$APELIN_PROJECT_ROOT/sources/openminis-apelin/src/ios/Minis.xcodeproj/project.pbxproj" <<'PY'
import os, pathlib, plistlib, re, stat, sys, zipfile
archive, destination, project = map(pathlib.Path, sys.argv[1:])
expected = {
    'Payload/Minis.app': 'com.openminis.app',
    'Payload/Minis.app/PlugIns/MinisShare.appex': 'com.openminis.app.ShareExtension',
    'Payload/Minis.app/PlugIns/MinisFileProvider.appex': 'com.openminis.app.FileProvider',
    'Payload/Minis.app/PlugIns/AgentWidgetExtension.appex': 'com.openminis.app.AgentWidget',
}
with zipfile.ZipFile(archive) as z:
    infos = z.infolist()
    names = {item.filename for item in infos}
    for item in infos:
        path = pathlib.PurePosixPath(item.filename)
        if path.is_absolute() or '..' in path.parts or '\\\\' in item.filename:
            raise SystemExit(f'Unsafe IPA archive path: {item.filename!r}')
    expected_metadata = {bundle + '/Info.plist' for bundle in expected}
    actual_metadata = {name for name in names if name.endswith(('.app/Info.plist', '.appex/Info.plist'))}
    if actual_metadata != expected_metadata:
        raise SystemExit(f'Unexpected app/extension bundles: {sorted(actual_metadata)}')
    for bundle, identifier in expected.items():
        info = plistlib.loads(z.read(bundle + '/Info.plist'))
        if info.get('CFBundleIdentifier') != identifier:
            raise SystemExit(f'Unexpected bundle id for {bundle}: {info.get("CFBundleIdentifier")}')
    if any('_CodeSignature' in pathlib.PurePosixPath(n).parts or n.endswith('/embedded.mobileprovision') for n in names):
        raise SystemExit('Signed or provisioned IPA is not accepted')
    text = project.read_text()
    marker = 'PRODUCT_BUNDLE_IDENTIFIER = com.openminis.app;'
    if marker not in text:
        raise SystemExit('App build settings were not found')
    version_line = re.search(r'MARKETING_VERSION = ([^;]+);', text[text.index(marker):])
    if not version_line:
        raise SystemExit('Could not determine app marketing version')
    version = version_line.group(1).strip()
    for item in infos:
        name = item.filename
        if not name.startswith('Payload/'):
            continue
        target = destination / name.removeprefix('Payload/')
        mode = item.external_attr >> 16
        if stat.S_ISLNK(mode):
            link = z.read(item).decode()
            resolved = (target.parent / link).resolve()
            if not resolved.is_relative_to(destination.resolve()):
                raise SystemExit(f'IPA symlink escapes app: {name}')
            target.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(link, target)
        elif item.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            os.chmod(target, stat.S_IMODE(mode) or 0o755)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(z.read(item))
            os.chmod(target, stat.S_IMODE(mode) or 0o644)
    (destination.parent / 'version').write_text(version)
PY
version="$(cat "$work/version")"
app="$work/app/Minis.app"
[ -d "$app" ] || { echo 'IPA must contain Payload/Minis.app' >&2; exit 3; }

prefix="${APELIN_PREFIX?}"
mkdir -p "$stage${prefix}/Applications/Minis.app" "$stage/DEBIAN"
cp -RP "$app/." "$stage${prefix}/Applications/Minis.app/"
cat > "$stage/DEBIAN/control" <<EOF
Package: com.openminis.apelin
Name: OpenMinis Apelin
Version: $version
Architecture: $APELIN_ARCHITECTURE
Maintainer: Huayuarc <738985817@qq.com>
Author: Huayuarc
Section: Applications
Description: OpenMinis iOS application packaged for Apelin
EOF

dpkg-deb -b --root-owner-group "$stage" "$APELIN_PACKAGE_DIR/" >/dev/null
set -- "$APELIN_PACKAGE_DIR"/*.deb
[ "$#" -eq 1 ] || { echo 'external build must produce exactly one deb' >&2; exit 8; }
dpkg-deb -f "$1" Package Version Architecture
