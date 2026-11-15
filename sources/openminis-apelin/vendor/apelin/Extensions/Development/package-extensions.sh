#!/usr/bin/env bash
# Package every development extension in this folder as a .deb per bootstrap
# layout, and verify what was packaged: the control fields, the data path,
# and the manifest and template digests read back out of the built package.
#
#   Extensions/Development/package-extensions.sh <output-directory> [roothide|rootless ...]
#
# With no flavor named, both are built. Set APELIN_EXTENSIONS_NO_BUILD=1 to
# skip the Mac build of every template (check-templates.py --no-build); the
# manifest, template and digest checks always run.
#
# An extension is data only — manifest.json, templates/, support/, LICENSE —
# installed at <prefix>/usr/share/apelin/development/<id>/, where @PREFIX@ is
# empty for roothide and /var/jb for rootless, as in Scripts/package-deb.sh.
# It ships no maintainer scripts and nothing executable: the app reads it,
# never runs it.

set -Eeuo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd -- "$here/../.." && pwd -P)"
schema_tools="$repository_root/Documents/Schemas/Tools"

if [[ "$#" -lt 1 ]]; then
    echo "usage: $0 <output-directory> [roothide|rootless ...]" >&2
    exit 64
fi
output_directory="$1"
shift
flavors=("$@")
[[ "${#flavors[@]}" -gt 0 ]] || flavors=(roothide rootless)

command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb is required (install it with your preferred package manager)" >&2; exit 69; }
command -v python3 >/dev/null || { echo "error: python3 is required" >&2; exit 69; }

if [[ "${APELIN_EXTENSIONS_NO_BUILD:-0}" == 1 ]]; then
    python3 -I -B "$here/check-templates.py" --no-build
else
    python3 -I -B "$here/check-templates.py"
fi

mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd -P)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/apelin-extensions.XXXXXX")"
trap 'rm -rf -- "${scratch:?}"' EXIT

# manifest_field <manifest> <field> [flavor]: one value the packager needs,
# read with the same loader the checks use.
manifest_field() {
    python3 -I -B - "$schema_tools" "$@" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import apelin_schema
manifest = apelin_schema.load_json(sys.argv[2])
field = sys.argv[3]
if field == "depends":
    flavor = sys.argv[4]
    relations = [f"wiki.qaq.apelin (>= {manifest['apelinCompatibility']['minimumAppVersion']})"]
    relations += manifest["requirements"].get("runtimeDependencies", {}).get(flavor, [])
    for component in manifest.get("support", {}).values():
        for relation in component.get("runtimeDependencies", {}).get(flavor, []):
            if relation not in relations:
                relations.append(relation)
    print(", ".join(relations))
elif field == "bootstraps":
    print(" ".join(manifest["requirements"]["bootstraps"]))
else:
    print(manifest[field])
PY
}

# verify_installed <installed extension directory>: the copy in the package
# passes the same checks as the source, digests included.
verify_installed() {
    python3 -I -B - "$schema_tools" "$1" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import apelin_schema
root = Path(sys.argv[2])
manifest = apelin_schema.load_json(root / "manifest.json")
errors = apelin_schema.validate_manifest(manifest)
for template in manifest["templates"]:
    errors += apelin_schema.check_template(root, template)
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(65)
PY
}

built=()
for extension in "$here"/*/; do
    extension="${extension%/}"
    [[ -f "$extension/manifest.json" ]] || continue
    package_id="$(manifest_field "$extension/manifest.json" id)"
    version="$(manifest_field "$extension/manifest.json" version)"
    bootstraps=" $(manifest_field "$extension/manifest.json" bootstraps) "
    control_template="$here/Packaging/$package_id/control"
    [[ -f "$control_template" ]] || { echo "error: missing $control_template" >&2; exit 66; }

    # Only what the app reads is shipped. Anything else in the folder is a
    # mistake to find here, not on a device.
    unexpected="$(find "$extension" -mindepth 1 -maxdepth 1 ! -name manifest.json ! -name LICENSE ! -name templates ! -name support -print)"
    [[ -z "$unexpected" ]] || { echo "error: unexpected entries in $package_id:" >&2; echo "$unexpected" >&2; exit 65; }
    [[ -z "$(find "$extension" -type l -print -quit)" ]] || { echo "error: $package_id contains a symbolic link" >&2; exit 65; }
    [[ -z "$(find "$extension" -name '.*' -print -quit)" ]] || { echo "error: $package_id contains a hidden file" >&2; exit 65; }

    for flavor in "${flavors[@]}"; do
        case "$flavor" in
        roothide) install_prefix= ; architecture=iphoneos-arm64e ;;
        rootless) install_prefix=/var/jb ; architecture=iphoneos-arm64 ;;
        *) echo "error: flavor must be roothide or rootless, got '$flavor'" >&2; exit 64 ;;
        esac
        [[ "$bootstraps" == *" $flavor "* ]] || { echo "skip $package_id ($flavor): not a supported bootstrap"; continue; }

        staging="$scratch/$package_id-$flavor"
        data_path="$install_prefix/usr/share/apelin/development/$package_id"
        mkdir -p "$staging/DEBIAN" "$staging$data_path"
        chmod 0755 "$staging"
        /usr/bin/ditto --norsrc --noextattr "$extension" "$staging$data_path"
        find "$staging" -type d -exec chmod 0755 {} +
        find "$staging$install_prefix" -type f -exec chmod 0644 {} +

        installed_size="$(du -sk "$staging$install_prefix/usr" | awk '{print $1}')"
        depends="$(manifest_field "$extension/manifest.json" depends "$flavor")"
        sed \
            -e "s/@VERSION@/$version/g" \
            -e "s/@ARCHITECTURE@/$architecture/g" \
            -e "s/@INSTALLED_SIZE@/$installed_size/g" \
            -e "s/@FLAVOR@/$flavor/g" \
            -e "s/@DEPENDS@/$depends/g" \
            "$control_template" >"$staging/DEBIAN/control"
        chmod 0644 "$staging/DEBIAN/control"
        [[ "$(sed -n 's/^Package: //p' "$staging/DEBIAN/control")" == "$package_id" ]] || {
            echo "error: the control template names another package than $package_id" >&2
            exit 65
        }
        if grep -nE '@[A-Z_]+@' "$staging/DEBIAN/control"; then
            echo "error: an unsubstituted placeholder is left in the control file (above)" >&2
            exit 65
        fi

        output_deb="$output_directory/${package_id}_${version}_${architecture}.deb"
        temporary_deb="$output_directory/.${package_id}_${version}_${architecture}.deb.tmp.$$"
        dpkg-deb --root-owner-group -Zzstd -b "$staging" "$temporary_deb" >/dev/null
        [[ "$(dpkg-deb -f "$temporary_deb" Package)" == "$package_id" ]]
        [[ "$(dpkg-deb -f "$temporary_deb" Version)" == "$version" ]]
        [[ "$(dpkg-deb -f "$temporary_deb" Architecture)" == "$architecture" ]]
        [[ "$(dpkg-deb -f "$temporary_deb" Depends)" == "$depends" ]]
        contents="$(dpkg-deb --contents "$temporary_deb")"
        grep -F ".$data_path/manifest.json" <<<"$contents" >/dev/null
        grep -F ".$data_path/LICENSE" <<<"$contents" >/dev/null
        if grep -vE "^[d-]rw[x-]r-[x-]r-[x-] root/(root|wheel) " <<<"$contents"; then
            echo "error: an entry above is not root-owned 0755/0644, or is not a file or directory" >&2
            exit 65
        fi
        if grep -E '^-' <<<"$contents" | grep -E '^-..x'; then
            echo "error: an executable file is in the package (above); extensions are data" >&2
            exit 65
        fi
        # Every entry is the data folder, inside it, or one of its parents.
        while read -r entry; do
            entry="${entry#./}"
            entry="/${entry%/}"
            [[ "$entry" == / || "$data_path" == "$entry"/* || "$entry" == "$data_path" || "$entry" == "$data_path"/* ]] || {
                echo "error: $entry is outside $data_path" >&2
                exit 65
            }
        done < <(awk '{print $6}' <<<"$contents")
        extracted="$scratch/extracted-$package_id-$flavor"
        dpkg-deb -x "$temporary_deb" "$extracted"
        verify_installed "$extracted$data_path"
        mv -f "$temporary_deb" "$output_deb"
        built+=("$output_deb")
        echo "Packaged $package_id $version ($flavor): $output_deb"
    done
done

[[ "${#built[@]}" -gt 0 ]] || { echo "error: nothing was packaged" >&2; exit 65; }
(cd "$output_directory" && shasum -a 256 "${built[@]##*/}")
