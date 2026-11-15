#!/usr/bin/env bash
# Package one agent-tool extension executable as a .deb for one bootstrap
# layout, ad-hoc signed with ldid, and verify what was packaged: the
# entitlements read back out of the signed binary, no build path in it, the
# reviewed notices, no placeholder left in anything shipped.
#
#   Scripts/package-agent-tool.sh <disassembler|assembler> <executable> <roothide|rootless> <output-directory>
#
# CHECKOUTS, when set, is SwiftPM's checkouts directory: every notice is then
# compared with the copy in the dependency it came from, and the assembler's
# corresponding-source archive is built from there.
#
# Layout, under the install prefix (empty for roothide, /var/jb rootless):
#   usr/libexec/apelin/agent-tools/<executable>
#   usr/share/apelin/agent-tools/<id>/manifest.json
#   usr/share/apelin/agent-tools/<id>/licenses/...

set -Eeuo pipefail

extension_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
repository_root="$(cd -- "$extension_root/../../.." && pwd -P)"

if [[ "$#" -ne 4 ]]; then
    echo "usage: $0 <disassembler|assembler> <executable> <roothide|rootless> <output-directory>" >&2
    exit 64
fi
tool="$1"
executable="$2"
flavor="$3"
output_directory="$4"
checkouts="${CHECKOUTS:-}"

case "$tool" in
disassembler | assembler) ;;
*) echo "error: unknown tool $tool; use disassembler or assembler" >&2; exit 64 ;;
esac
# Roothide installs into the jbroot it picked this boot, so its paths carry
# no prefix; a rootless bootstrap names /var/jb in every path.
case "$flavor" in
roothide) architecture=iphoneos-arm64e; install_prefix= ;;
rootless) architecture=iphoneos-arm64; install_prefix=/var/jb ;;
*) echo "error: unknown flavor $flavor; use roothide or rootless" >&2; exit 64 ;;
esac

packaging="$extension_root/Packaging/$tool"
manifest="$packaging/manifest.json"
control_template="$packaging/control"
entitlements="$packaging/entitlements.plist"
review="$extension_root/Licenses/review.json"
for input in "$manifest" "$control_template" "$review"; do
    [[ -f "$input" ]] || { echo "error: missing packaging input: $input" >&2; exit 66; }
done
[[ -x "$executable" ]] || { echo "error: $executable is not an executable" >&2; exit 66; }

# json <file> <key>... prints the value at that path: a string as is, an
# array as its length. Keys may contain dots, which plutil's paths cannot.
json() {
    python3 -I -c 'import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2:]:
    value = value[int(key)] if isinstance(value, list) else value[key]
print(len(value) if isinstance(value, list) else value)' "$@"
}
package_id="$(json "$manifest" id)"
version="$(json "$manifest" version)"
executable_path="$(json "$manifest" executable)"
[[ "$package_id" =~ ^wiki\.qaq\.apelin\.agent-tools\.[a-z0-9-]+$ ]] || { echo "error: unexpected package id $package_id" >&2; exit 65; }
[[ "$version" =~ ^[0-9A-Za-z.+~-]+$ ]] || { echo "error: invalid version $version" >&2; exit 65; }
[[ "$executable_path" == "usr/libexec/apelin/agent-tools/$(basename "$executable")" ]] || {
    echo "error: the manifest launches $executable_path, not $(basename "$executable")" >&2
    exit 65
}
[[ "$(sed -n 's/^Package: //p' "$control_template")" == "$package_id" ]] || {
    echo "error: the control template names a package other than $package_id" >&2
    exit 65
}

# The binary: one arm64 slice built for iOS, not linked against libvroot
# (a native binary resolves physical paths itself).
[[ "$(lipo -archs "$executable")" == arm64 ]] || { echo "error: $executable is not a thin arm64 binary" >&2; exit 65; }
otool -l "$executable" | awk '/cmd LC_BUILD_VERSION/ {found = 1} found && /platform/ {print $2; exit}' | grep -qx 2 || {
    echo "error: $executable is not built for iOS" >&2
    exit 65
}
if otool -L "$executable" | grep -q libvroot; then
    echo "error: $(basename "$executable") links libvroot" >&2
    exit 65
fi
# The disassembler package must carry no GPL code: Keystone links into the
# assembler alone.
if [[ "$tool" == disassembler ]] && nm -U "$executable" 2>/dev/null | grep -q ' _ks_asm$'; then
    echo "error: the disassembler links Keystone" >&2
    exit 65
fi

mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd -P)"
output_deb="$output_directory/${package_id}_${version}_${architecture}.deb"
staging="$(mktemp -d "${TMPDIR:-/tmp}/apelin-agent-tool.XXXXXX")"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/apelin-agent-tool-scratch.XXXXXX")"
temporary_deb="$output_directory/.$(basename "$output_deb").tmp.$$"
trap 'rm -rf -- "${staging:?}" "${scratch:?}"; rm -f "$temporary_deb"' EXIT
chmod 0755 "$staging"

root="$staging$install_prefix"
installed_executable="$root/$executable_path"
data_directory="$root/usr/share/apelin/agent-tools/$package_id"
mkdir -p "$staging/DEBIAN" "$(dirname "$installed_executable")" "$data_directory/licenses"
/usr/bin/ditto "$executable" "$installed_executable"
cp "$manifest" "$data_directory/manifest.json"

# Every notice the manifest lists, from the reviewed copy, checked against
# its reviewed hash and, with CHECKOUTS, against the dependency's own file.
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
license_count="$(json "$manifest" licenseFiles)"
license_entries=()
for ((index = 0; index < license_count; index++)); do
    entry="$(json "$manifest" licenseFiles "$index")"
    [[ "$entry" =~ ^licenses/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$ ]] || { echo "error: invalid license path $entry; it must be licenses/<name> or licenses/<folder>/<name>" >&2; exit 65; }
    license_entries+=("$entry")
    relative="${entry#licenses/}"
    destination="$data_directory/$entry"
    mkdir -p "$(dirname "$destination")"
    if [[ "$relative" == SOURCE.md ]]; then
        continue # written below, with the archive's hash
    fi
    component="${relative%%/*}"
    file="${relative#*/}"
    expected="$(json "$review" components "$component" files "$file" sha256 2>/dev/null)" || {
        echo "error: $entry is not in Licenses/review.json" >&2
        exit 65
    }
    if [[ "$component" == Apelin ]]; then
        source_file="$repository_root/LICENSE"
    else
        source_file="$extension_root/Licenses/$component/$file"
    fi
    [[ "$(sha256 "$source_file")" == "$expected" ]] || {
        echo "error: $source_file differs from the reviewed text; read it and update Licenses/review.json" >&2
        exit 65
    }
    if [[ -n "$checkouts" && "$component" != Apelin ]]; then
        upstream="$checkouts/$(json "$review" components "$component" files "$file" checkout)"
        [[ -f "$upstream" && "$(sha256 "$upstream")" == "$expected" ]] || {
            echo "error: $upstream no longer matches the reviewed $component notice; read it and update Licenses/" >&2
            exit 65
        }
    fi
    cp "$source_file" "$destination"
done

# The assembler is GPL-2.0: its corresponding source is archived beside the
# package, and the package says where to find it.
if [[ "$tool" == assembler ]]; then
    [[ -n "$checkouts" ]] || { echo "error: the assembler needs CHECKOUTS for its corresponding source" >&2; exit 64; }
    keystone_revision="$(json "$review" components libkeystone-spm revision)"
    for component in libkeystone-spm libcapstone-spm; do
        revision="$(json "$review" components "$component" revision)"
        grep -q "\"revision\" : \"$revision\"" "$extension_root/Package.resolved" || {
            echo "error: Package.resolved pins a $component revision other than the reviewed $revision" >&2
            exit 65
        }
    done
    apelin_commit="$(git -C "$repository_root" rev-parse HEAD)"
    if [[ -n "$(git -C "$repository_root" status --porcelain -- Packages/ApelinToolHost Extensions/AgentTools/Disassembler LICENSE)" ]]; then
        apelin_commit="$apelin_commit, with uncommitted changes"
    fi
    archive_name="${package_id}_${version}_source.tar.xz"
    archive="$output_directory/$archive_name"
    if [[ ! -f "$archive" ]]; then
        source_tree="$scratch/source"
        mkdir -p "$source_tree/Apelin/Packages" "$source_tree/Apelin/Extensions/AgentTools" "$source_tree/Dependencies"
        excludes=(--exclude .build --exclude .swiftpm --exclude build --exclude .DS_Store --exclude .git)
        rsync -a "${excludes[@]}" "$repository_root/LICENSE" "$source_tree/Apelin/"
        rsync -a "${excludes[@]}" "$repository_root/Packages/ApelinToolHost" "$source_tree/Apelin/Packages/"
        rsync -a "${excludes[@]}" "$extension_root" "$source_tree/Apelin/Extensions/AgentTools/"
        rsync -a "${excludes[@]}" "$checkouts/libkeystone-spm" "$checkouts/libcapstone-spm" "$source_tree/Dependencies/"
        tar --uid 0 --gid 0 --uname root --gname wheel --no-xattrs --no-mac-metadata -cJf "$scratch/$archive_name" -C "$source_tree" Apelin Dependencies
        mv "$scratch/$archive_name" "$archive"
    fi
    sed \
        -e "s|@VERSION@|$version|g" \
        -e "s|@SOURCE_ARCHIVE@|$archive_name|g" \
        -e "s|@SOURCE_SHA256@|$(sha256 "$archive")|g" \
        -e "s|@APELIN_COMMIT@|$apelin_commit|g" \
        -e "s|@KEYSTONE_REVISION@|$keystone_revision|g" \
        "$packaging/SOURCE.md.in" >"$data_directory/licenses/SOURCE.md"
fi

# Strip, then refuse any private build path left in the binary.
if [[ "${CONFIGURATION:-Release}" != Debug ]]; then
    /usr/bin/strip -x "$installed_executable"
    for private_path in "$repository_root" "${checkouts%/checkouts}" "${GITHUB_WORKSPACE:-}" "${RUNNER_TEMP:-}" "$HOME"; do
        [[ -z "$private_path" || "$private_path" == / ]] && continue
        if LC_ALL=C grep -aF "$private_path" "$installed_executable" >/dev/null; then
            echo "error: $(basename "$installed_executable") embeds a private build path ($private_path)" >&2
            exit 65
        fi
    done
fi

# Sign. The disassembler reads app bundles and carries exactly the
# entitlements its plist names; the assembler opens no file and carries none.
signed_entitlements="$scratch/entitlements.plist"
if [[ -f "$entitlements" ]]; then
    ldid -S"$entitlements" -Cadhoc "$installed_executable"
    ldid -e "$installed_executable" >"$signed_entitlements"
    for key in platform-application com.apple.private.security.no-sandbox com.apple.private.security.storage.AppBundles; do
        [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$signed_entitlements" 2>/dev/null || true)" == true ]] || {
            echo "error: the signed executable is missing $key" >&2
            exit 65
        }
    done
    for key in wiki.qaq.apelin.client com.apple.private.security.storage.AppDataContainers \
        com.apple.security.get-task-allow task_for_pid-allow; do
        [[ -z "$(/usr/libexec/PlistBuddy -c "Print :$key" "$signed_entitlements" 2>/dev/null || true)" ]] || {
            echo "error: an agent tool must not carry $key" >&2
            exit 65
        }
    done
else
    ldid -S -Cadhoc "$installed_executable"
    [[ -z "$(ldid -e "$installed_executable" | tr -d '[:space:]')" ]] || {
        echo "error: $(basename "$installed_executable") is signed with entitlements it should not have" >&2
        exit 65
    }
fi

chmod 0755 "$installed_executable"
find "$staging" -type d -exec chmod 0755 {} +
find "$data_directory" -type f -exec chmod 0644 {} +

installed_size="$(du -sk "$root/usr" | awk '{print $1}')"
sed \
    -e "s/@VERSION@/$version/g" \
    -e "s/@ARCHITECTURE@/$architecture/g" \
    -e "s/@INSTALLED_SIZE@/$installed_size/g" \
    -e "s/@FLAVOR@/$flavor/g" \
    "$control_template" >"$staging/DEBIAN/control"
chmod 0644 "$staging/DEBIAN/control"
if grep -rnE '@[A-Z_]+@' "$staging/DEBIAN/control" "$data_directory"; then
    echo "error: an unsubstituted placeholder is left in the package (above)" >&2
    exit 65
fi

dpkg-deb --root-owner-group -Zzstd -b "$staging" "$temporary_deb" >/dev/null
[[ "$(dpkg-deb -f "$temporary_deb" Package)" == "$package_id" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Version)" == "$version" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Architecture)" == "$architecture" ]]
contents="$(dpkg-deb --contents "$temporary_deb")"
grep -F ".$install_prefix/$executable_path" <<<"$contents" | grep -q '^-rwxr-xr-x root/root' || {
    echo "error: the executable is not root-owned 0755 in the package" >&2
    exit 65
}
grep -F ".$install_prefix/usr/share/apelin/agent-tools/$package_id/manifest.json" <<<"$contents" | grep -q '^-rw-r--r-- root/root'
for ((index = 0; index < license_count; index++)); do
    grep -qF ".$install_prefix/usr/share/apelin/agent-tools/$package_id/${license_entries[index]}" <<<"$contents"
done
if awk '{print $1}' <<<"$contents" | grep -qE '^.{5}w|^.{8}w'; then
    echo "error: something in the package is group- or world-writable" >&2
    exit 65
fi

mv -f "$temporary_deb" "$output_deb"
echo "Packaged $package_id ($flavor): $output_deb"
shasum -a 256 "$output_deb"
