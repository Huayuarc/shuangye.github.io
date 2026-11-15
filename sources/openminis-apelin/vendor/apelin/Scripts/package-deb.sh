#!/usr/bin/env bash
# Package one build of Apelin.app (its widget extension inside), apelind and
# its workers as a .deb for one bootstrap layout, ad-hoc signed with ldid, and verify what was packaged: the
# entitlements read back out of the signed binaries, no build path in any of
# them, no placeholder left in anything shipped.

set -Eeuo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

if [[ "$#" -ne 13 ]]; then
    echo "usage: $0 <app> <daemon> <control> <app-entitlements> <daemon-entitlements> <launch-plist> <output-deb> <package-id> <version> <architecture> <install-prefix> <flavor> <workers-dir>" >&2
    exit 64
fi

app_bundle="$1"
daemon_binary="$2"
control_template="$3"
app_entitlements="$4"
daemon_entitlements="$5"
launch_plist="$6"
output_deb="$7"
package_id="$8"
version="$9"
architecture="${10}"
# Empty for roothide, which installs into the jbroot it picked this boot, and
# "/var/jb" for a rootless bootstrap, which has to be named in every path the
# package ships — including the ones inside the launch daemon and the
# maintainer scripts.
install_prefix="${11}"
flavor="${12}"
# Where the worker executables were built; each is installed at
# <prefix>/usr/libexec/apelin/<name> and signed with
# Packaging/Workers/<name>.entitlements.
workers_dir="${13}"
workers=(apelin-environment apelin-build apelin-agent apelin-diagnostics apelin-log-reader)
# SwiftPM resource bundles a worker reads at run time through Bundle.module.
# Xcode's accessor for a command-line tool looks beside the executable
# (Bundle.main.bundleURL) and names no build path, so each is installed next
# to the workers. KWWKAI's model catalogue is the one apelin-agent needs; a
# missing one is a fatalError on the first session.
worker_resources=(kwwk_KWWKAI.bundle)
# Back-deployed Swift runtime libraries a worker links by @rpath. Xcode embeds
# them into an app bundle only, never beside a command-line tool, so the
# toolchain's copy is installed next to the workers and signed like them. The
# tool targets' rpaths are /usr/lib/swift first, then @executable_path: the
# OS copy wins where the OS has one (libswiftCompatibilitySpan from iOS 26),
# and iOS 16–18 load this one. Without it apelin-agent dies in dyld there.
worker_runtime_libraries=(libswiftCompatibilitySpan.dylib)
packaging_root="$(cd "$(dirname "$control_template")/.." && pwd -P)"
# Sourced by the bootstrap's /etc/profile after it sets PATH anew: puts the
# toolchain Apelin's terminal named in APELIN_TOOLCHAIN_BIN back in front.
login_profile="$packaging_root/profile.d/wiki.qaq.apelin.sh"
[[ -f "$login_profile" ]] || { echo "error: missing packaging input: $login_profile" >&2; exit 66; }
/bin/sh -n "$login_profile" || { echo "error: $login_profile is not valid sh" >&2; exit 65; }

# The one app extension: the widgets (Widgets/Extension), sandboxed, signed
# with Packaging/ApelinWidgets.entitlements, sharing one App Group with the
# app and nothing else.
widget_appex=ApelinWidgets.appex
widget_bundle_identifier=wiki.qaq.apelin.widgets
widget_entitlements="$packaging_root/ApelinWidgets.entitlements"
app_group=group.wiki.qaq.apelin

[[ -d "$app_bundle" && -f "$app_bundle/Info.plist" ]] || { echo "error: $app_bundle is not a complete app bundle; expected a directory containing Info.plist" >&2; exit 66; }
[[ -x "$daemon_binary" ]] || { echo "error: daemon binary is missing" >&2; exit 66; }
for input in "$control_template" "$app_entitlements" "$daemon_entitlements" "$launch_plist" "$widget_entitlements"; do
    [[ -f "$input" ]] || { echo "error: missing packaging input: $input" >&2; exit 66; }
done
for resource in "${worker_resources[@]}"; do
    [[ -f "$workers_dir/$resource/Info.plist" ]] || { echo "error: worker resource bundle is missing: $resource" >&2; exit 66; }
done
for worker in "${workers[@]}"; do
    [[ -x "$workers_dir/$worker" ]] || { echo "error: worker binary is missing: $worker" >&2; exit 66; }
    [[ -f "$packaging_root/Workers/$worker.entitlements" ]] || { echo "error: Packaging/Workers/$worker.entitlements is missing" >&2; exit 66; }
done
swift_toolchain_lib="$(dirname "$(xcrun --sdk iphoneos --find swiftc)")/../lib"
runtime_library_source() {
    local library="$1" candidates
    shopt -s nullglob
    candidates=("$swift_toolchain_lib"/swift-*/iphoneos/"$library")
    shopt -u nullglob
    [[ "${#candidates[@]}" -eq 1 ]] || {
        echo "error: expected exactly one $library in the toolchain's back-deployment folders, found ${#candidates[@]}" >&2
        exit 66
    }
    printf '%s\n' "${candidates[0]}"
}
runtime_library_sources=()
for library in "${worker_runtime_libraries[@]}"; do
    source_library="$(runtime_library_source "$library")"
    [[ "$(otool -D "$source_library" | tail -n 1)" == "/usr/lib/swift/$library" ]] || {
        echo "error: $source_library is not installed as /usr/lib/swift/$library" >&2
        exit 65
    }
    runtime_library_sources+=("$source_library")
done
[[ "$output_deb" == *.deb ]] || { echo "error: output must end in .deb" >&2; exit 64; }
[[ "$package_id" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || { echo "error: invalid package ID '$package_id'; use lowercase letters, digits, '+', '.' and '-'" >&2; exit 64; }
[[ "$version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] || { echo "error: invalid version '$version'" >&2; exit 64; }
[[ "$install_prefix" =~ ^(/[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]] || { echo "error: invalid install prefix '$install_prefix'" >&2; exit 64; }
case "$flavor:$architecture:$install_prefix" in
rootless:iphoneos-arm64:/var/jb | roothide:iphoneos-arm64e:) ;;
*) echo "error: flavor, architecture and install prefix name different bootstrap layouts" >&2; exit 64 ;;
esac
# Roothide's launchctl strips /rootfs off a launchd path to reach the system;
# rootless's passes the path through. Empty when the plist uses none.
case "$flavor" in
roothide) rootfs=/rootfs ;;
*) rootfs= ;;
esac

# Native binaries keep physical paths; libroot's vroot would rewrite one side
# of the XPC boundary and not the other.
app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_bundle/Info.plist")"
# Exactly the widget extension in PlugIns: another one is a second process
# under the app's bundle id with none of its review, so the packager is
# changed for it on purpose, not by accident.
shopt -s nullglob
built_appexes=("$app_bundle/PlugIns"/*)
shopt -u nullglob
[[ "${#built_appexes[@]}" -eq 1 && "$(basename "${built_appexes[0]}")" == "$widget_appex" ]] || {
    echo "error: $app_bundle/PlugIns must hold $widget_appex and nothing else; sign and verify a new extension in this packager first" >&2
    exit 65
}
widget_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_bundle/PlugIns/$widget_appex/Info.plist")"
[[ -x "$app_bundle/PlugIns/$widget_appex/$widget_executable" ]] || {
    echo "error: $widget_appex has no executable" >&2
    exit 65
}
native_binaries=("$daemon_binary" "$app_bundle/$app_executable" "$app_bundle/PlugIns/$widget_appex/$widget_executable")
for worker in "${workers[@]}"; do
    native_binaries+=("$workers_dir/$worker")
done
for native_binary in "${native_binaries[@]}"; do
    if otool -L "$native_binary" | grep -q 'libvroot'; then
        echo "error: $(basename "$native_binary") links libvroot; native binaries resolve physical paths themselves" >&2
        exit 65
    fi
done

bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Info.plist")"
[[ "$bundle_identifier" == wiki.qaq.apelin && -x "$app_bundle/$app_executable" ]] || {
    echo "error: $app_bundle is not the Apelin app; expected bundle ID wiki.qaq.apelin and an executable $app_executable" >&2
    exit 65
}

# The package version comes from Configuration/Version.xcconfig, which is also
# what the app was built with — refuse to ship a .deb that disagrees.
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Info.plist")"
[[ "$app_version" == "$version" ]] || {
    echo "error: app version '$app_version' does not match package version '$version'" >&2
    exit 65
}
# An embedded extension carries its app's versions, under its app's id.
widget_plist="$app_bundle/PlugIns/$widget_appex/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$widget_plist")" == "$widget_bundle_identifier" \
    && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$widget_plist")" == "$app_version" \
    && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$widget_plist")" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_bundle/Info.plist")" \
    && "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$widget_plist")" == com.apple.widgetkit-extension ]] || {
    echo "error: $widget_appex must be $widget_bundle_identifier, a WidgetKit extension with the app's version and build" >&2
    exit 65
}

# Settings ▸ About ▸ Licenses reads this; the Collect Licenses build phase
# writes it, and a bundle without it is a build that skipped the phase.
[[ -f "$app_bundle/Licenses.json" ]] || {
    echo "error: $app_bundle has no Licenses.json — the Collect Licenses build phase did not run" >&2
    exit 65
}

# SwiftPM resource bundles the app reads through Bundle.module, which looks
# for each beside the executable. Runestone's (vendored, Packages/Runestone)
# holds its theme colours, its strings and its privacy manifest; without it
# the text view's DefaultTheme force-unwraps a missing colour. Its queries
# are compiled in, so the bundle holds no code and no query.
runestone_bundle=Runestone_Runestone.bundle
app_resources=("$runestone_bundle")
for resource in "${app_resources[@]}"; do
    [[ -f "$app_bundle/$resource/Info.plist" ]] || {
        echo "error: $app_bundle lacks $resource — Xcode did not copy the package's resources" >&2
        exit 65
    }
done
for required in Assets.car PrivacyInfo.xcprivacy en.lproj/Localizable.strings; do
    [[ -e "$app_bundle/$runestone_bundle/$required" ]] || {
        echo "error: $runestone_bundle lacks $required" >&2
        exit 65
    }
done

# The app icon ships as three JPEGs; an Icon Composer `.icon` in a target
# would add six lossless 1024² renders to Assets.car.
[[ -z "$(/usr/bin/find "$app_bundle" -name '*.icon' -print -quit)" ]] || {
    echo "error: an .icon is in the app bundle; the icon ships as AppIcon.appiconset only" >&2
    exit 65
}

output_name="$(basename "$output_deb")"
mkdir -p "$(dirname "$output_deb")"
output_directory="$(cd "$(dirname "$output_deb")" && pwd -P)"
output_deb="$output_directory/$output_name"
staging="$(mktemp -d "${TMPDIR:-/tmp}/apelin-deb.XXXXXX")"
temporary_deb="$output_directory/.$output_name.tmp.$$"
# Scratch files live in their own per-run directory: macOS mktemp only
# substitutes trailing Xs, so a file template with a suffix is a fixed path.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/apelin-deb-scratch.XXXXXX")"
trap 'rm -rf -- "${staging:?}" "${scratch:?}"; rm -f "$temporary_deb"' EXIT
app_signed_entitlements="$scratch/app-entitlements.plist"
daemon_signed_entitlements="$scratch/daemon-entitlements.plist"
chmod 0755 "$staging"

debian="$staging/DEBIAN"
installed_root="$staging$install_prefix"
installed_app="$installed_root/Applications/Apelin.app"
installed_daemon="$installed_root/usr/libexec/apelind"
installed_plist="$installed_root/Library/LaunchDaemons/wiki.qaq.apelind.plist"
installed_workers="$installed_root/usr/libexec/apelin"
installed_profile="$installed_root/etc/profile.d/wiki.qaq.apelin.sh"
mkdir -p "$debian" "$(dirname "$installed_app")" "$(dirname "$installed_daemon")" "$(dirname "$installed_plist")" "$installed_workers" \
    "$(dirname "$installed_profile")"
cp "$login_profile" "$installed_profile"
chmod 0644 "$installed_profile"
/usr/bin/ditto "$app_bundle" "$installed_app"
/usr/bin/ditto "$daemon_binary" "$installed_daemon"
sed -e "s|@PREFIX@|$install_prefix|g" -e "s|@ROOTFS@|$rootfs|g" "$launch_plist" >"$installed_plist"
# The daemon recovers its install root by stripping this suffix off its own
# executable path, so the plist has to launch it by the path it is installed
# at — a mismatch and every bootstrap path it derives is wrong.
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$installed_plist")" == "$install_prefix/usr/libexec/apelind" ]] || {
    echo "error: the launch daemon does not point at the installed apelind" >&2
    exit 65
}
rm -rf -- "${installed_app:?}/_CodeSignature"
rm -f "$installed_app/embedded.mobileprovision"
chmod 0755 "$installed_daemon"
# The session host spawns these only if they are root-owned and writable by
# root alone; dpkg-deb --root-owner-group makes them root's.
for worker in "${workers[@]}"; do
    /usr/bin/ditto "$workers_dir/$worker" "$installed_workers/$worker"
    chmod 0755 "$installed_workers/$worker"
done
for resource in "${worker_resources[@]}"; do
    /usr/bin/ditto "$workers_dir/$resource" "$installed_workers/$resource"
    chmod -R u=rwX,go=rX "$installed_workers/$resource"
done
for source_library in "${runtime_library_sources[@]}"; do
    library="${source_library##*/}"
    /usr/bin/ditto "$source_library" "$installed_workers/$library"
    chmod 0755 "$installed_workers/$library"
done
chmod 0644 "$installed_plist"

strip_and_check_private_paths() {
    local binary="$1"
    local private_path
    /usr/bin/strip -xS "$binary"
    # Debug diagnostics may retain source paths; only shipped builds forbid them.
    if [[ "${CONFIGURATION:-Release}" == Debug ]]; then
        return
    fi
    for private_path in "$repository_root" "${GITHUB_WORKSPACE:-}" "${RUNNER_TEMP:-}"; do
        [[ -z "$private_path" || "$private_path" == / ]] && continue
        if LC_ALL=C grep -aF "$private_path" "$binary" >/dev/null; then
            echo "error: $(basename "$binary") embeds a private build path" >&2
            exit 65
        fi
    done
}

# Every embedded library, inside out, before the app that loads it. The Swift
# compatibility dylibs the toolchain copies in keep Apple's own signature,
# which a jailbroken iOS refuses outside the system ("code signature
# invalid"), and only on the older device that actually loads them.
shopt -s nullglob
embedded=("$installed_app/Frameworks"/*.dylib "$installed_app/Frameworks"/*.framework)
shopt -u nullglob
for library in ${embedded[@]+"${embedded[@]}"}; do
    if [[ -d "$library" ]]; then
        rm -rf -- "${library:?}/_CodeSignature"
        library_binary="$library/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$library/Info.plist")"
    else
        library_binary="$library"
    fi
    strip_and_check_private_paths "$library_binary"
    ldid -S -Cadhoc "$library_binary"
done

strip_and_check_private_paths "$installed_app/$app_executable"
strip_and_check_private_paths "$installed_daemon"

ldid -S"$app_entitlements" -Cadhoc "$installed_app/$app_executable"
ldid -S"$daemon_entitlements" -Cadhoc "$installed_daemon"
for worker in "${workers[@]}"; do
    strip_and_check_private_paths "$installed_workers/$worker"
    ldid -S"$packaging_root/Workers/$worker.entitlements" -Cadhoc "$installed_workers/$worker"
done
# Apple's signature on the toolchain's copy is refused outside the system,
# like the app's embedded Swift libraries above.
for library in "${worker_runtime_libraries[@]}"; do
    ldid -S -Cadhoc "$installed_workers/$library"
done

# The widget extension is its own Mach-O with its own signature: Xcode's is as
# useless as the app's, and the system refuses to load an appex whose
# signature does not verify.
installed_widget="$installed_app/PlugIns/$widget_appex"
rm -rf -- "${installed_widget:?}/_CodeSignature"
rm -f "$installed_widget/embedded.mobileprovision"
strip_and_check_private_paths "$installed_widget/$widget_executable"
ldid -S"$widget_entitlements" -Cadhoc "$installed_widget/$widget_executable"

# Every strong @rpath dependency of every shipped Mach-O resolves to a file in
# the package or to a library the OS has on the floor; dyld would otherwise
# kill the process before main, and only on the older device.
python3 -I -B "$repository_root/Scripts/check-rpath-dependencies.py" "$staging" "$install_prefix"

require_true() {
    local plist="$1"
    local key="$2"
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)" == true ]] || {
        echo "error: signed executable is missing entitlement: $key" >&2
        exit 65
    }
}

require_absent() {
    local plist="$1"
    local key="$2"
    local label="$3"
    [[ -z "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)" ]] || {
        echo "error: $label must not carry $key" >&2
        exit 65
    }
}

# Exactly the one App Group the app and the widget extension share.
require_app_group() {
    local plist="$1"
    local label="$2"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$plist" 2>/dev/null | sed -n 's/^ *\(group\.[^ ]*\)$/\1/p')" == "$app_group" ]] || {
        echo "error: $label must carry exactly the App Group $app_group" >&2
        exit 65
    }
}

# The app reaches the daemon (the client marker the daemon authenticates
# against, plus the mach-lookup exception for the service name), reads other
# apps' bundles and containers beside `no-sandbox`, and carries the GPU list
# every ad-hoc signed app needs before system frameworks draw. Spawning is the
# daemon's alone — the app has no process API.
ldid -e "$installed_app/$app_executable" >"$app_signed_entitlements"
for key in wiki.qaq.apelin.client \
    platform-application \
    com.apple.private.security.no-sandbox \
    com.apple.private.security.storage.AppBundles \
    com.apple.private.security.storage.AppDataContainers; do
    require_true "$app_signed_entitlements" "$key"
done
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.iokit-user-client-class:0' "$app_signed_entitlements" 2>/dev/null || true)" ]] || {
    echo "error: app is missing the GPU iokit-user-client-class list" >&2
    exit 65
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.exception.mach-lookup.global-name:0' "$app_signed_entitlements")" == wiki.qaq.apelin.service ]] || {
    echo "error: app is missing the daemon mach lookup entitlement" >&2
    exit 65
}
# The app asks for notifications under its own bundle id, and says it posts
# local ones; the daemon posts as the app under the same id. Either half
# missing leaves authorization false with no error anywhere but the device log.
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.private.usernotifications.bundle-identifiers:0' "$app_signed_entitlements" 2>/dev/null || true)" == "$bundle_identifier" ]] || {
    echo "error: app is missing the usernotifications bundle-identifiers entitlement for $bundle_identifier" >&2
    exit 65
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SBAppUsesLocalNotifications' "$installed_app/Info.plist" 2>/dev/null || true)" == true ]] || {
    echo "error: app Info.plist is missing SBAppUsesLocalNotifications" >&2
    exit 65
}
# The app opens its own data policy at launch (NetworkAccess.swift); without
# both values CoreTelephony refuses, and the app stays offline wherever the
# system holds that policy denied.
for value in spi data-allowed-write; do
    /usr/libexec/PlistBuddy -c 'Print :com.apple.CommCenter.fine-grained' "$app_signed_entitlements" 2>/dev/null \
        | grep -Eq "^[[:space:]]*$value\$" || {
        echo "error: app is missing com.apple.CommCenter.fine-grained $value" >&2
        exit 65
    }
done
for key in com.apple.private.security.no-container \
    wiki.qaq.irisin.client \
    com.apple.private.security.container-required \
    com.apple.private.skip-library-validation; do
    require_absent "$app_signed_entitlements" "$key" "the app"
done
require_app_group "$app_signed_entitlements" "the app"

# The widget extension stays a standard sandboxed extension: the App Group and
# nothing that widens it. apelind authenticates peers by their binary, so an
# extension with the client key or the service's Mach name would be an
# entrance nobody designed — what was signed is checked, not what was asked.
widget_signed_entitlements="$scratch/widget-entitlements.plist"
ldid -e "$installed_widget/$widget_executable" >"$widget_signed_entitlements"
require_app_group "$widget_signed_entitlements" "$widget_appex"
for key in wiki.qaq.apelin.client \
    wiki.qaq.irisin.client \
    platform-application \
    com.apple.private.security.no-sandbox \
    com.apple.private.security.no-container \
    com.apple.private.security.container-required \
    com.apple.private.security.storage.AppBundles \
    com.apple.private.security.storage.AppDataContainers \
    com.apple.private.skip-library-validation \
    com.apple.security.exception.mach-lookup.global-name \
    com.apple.security.iokit-user-client-class; do
    require_absent "$widget_signed_entitlements" "$key" "$widget_appex"
done

# The daemon: platform, unsandboxed, the two storage classes, irisind's
# client key (its session host installs through Irisin), and never Apelin's
# client marker — a daemon that could pass for its own client is an entrance
# nobody designed.
ldid -e "$installed_daemon" >"$daemon_signed_entitlements"
for key in platform-application \
    com.apple.private.security.no-sandbox \
    wiki.qaq.irisin.client \
    com.apple.private.security.storage.AppBundles \
    com.apple.private.security.storage.AppDataContainers; do
    require_true "$daemon_signed_entitlements" "$key"
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.private.usernotifications.bundle-identifiers:0' "$daemon_signed_entitlements" 2>/dev/null || true)" == "$bundle_identifier" ]] || {
    echo "error: apelind is missing the usernotifications bundle-identifiers entitlement for $bundle_identifier" >&2
    exit 65
}
require_absent "$daemon_signed_entitlements" wiki.qaq.apelin.client apelind
require_absent "$daemon_signed_entitlements" com.apple.security.iokit-user-client-class apelind

# The workers: platform and unsandboxed, and never a way into the public
# service — no client marker, no lookup of its Mach name. They reach the
# session host only through the socketpair it spawned them with.
for worker in "${workers[@]}"; do
    worker_signed_entitlements="$scratch/$worker-entitlements.plist"
    ldid -e "$installed_workers/$worker" >"$worker_signed_entitlements"
    for key in platform-application com.apple.private.security.no-sandbox; do
        require_true "$worker_signed_entitlements" "$key"
    done
    require_absent "$worker_signed_entitlements" wiki.qaq.apelin.client "$worker"
    require_absent "$worker_signed_entitlements" wiki.qaq.irisin.client "$worker"
    require_absent "$worker_signed_entitlements" com.apple.private.usernotifications.bundle-identifiers "$worker"
    require_absent "$worker_signed_entitlements" com.apple.security.exception.mach-lookup.global-name "$worker"
done

installed_size="$(du -sk "$installed_root/Applications" "$installed_root/usr" "$installed_root/Library" | awk '{total += $1} END {print total}')"
sed \
    -e "s/@VERSION@/$version/g" \
    -e "s/@ARCHITECTURE@/$architecture/g" \
    -e "s/@INSTALLED_SIZE@/$installed_size/g" \
    -e "s/@FLAVOR@/$flavor/g" \
    "$control_template" >"$debian/control"
[[ "$(sed -n 's/^Package: //p' "$debian/control")" == "$package_id" ]] || {
    echo "error: the control template names a package other than $package_id" >&2
    exit 65
}

# What dpkg will run is the substituted copy, so that is the one checked: it
# has to parse, and no packager placeholder may be left in anything shipped.
for script in postinst prerm postrm; do
    sed -e "s|@PREFIX@|$install_prefix|g" "$packaging_root/DEBIAN/$script" >"$debian/$script"
    sh -n "$debian/$script"
done
chmod 0644 "$debian/control"
chmod 0755 "$debian/postinst" "$debian/prerm" "$debian/postrm"
if grep -nE '@[A-Z_]+@' "$debian/control" "$debian/postinst" "$debian/prerm" "$debian/postrm" "$installed_plist"; then
    echo "error: an unsubstituted placeholder is left in the package (above)" >&2
    exit 65
fi

dpkg-deb --root-owner-group -Zzstd -b "$staging" "$temporary_deb"
[[ "$(dpkg-deb -f "$temporary_deb" Package)" == "$package_id" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Version)" == "$version" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Architecture)" == "$architecture" ]]
# The IDE recommends the four development extensions, so they come by
# default and removing one is not an error; it never depends on one, and
# never depends on, recommends or suggests an agent tool extension (some
# are GPL, and the user installs them on purpose).
[[ "$(dpkg-deb -f "$temporary_deb" Recommends)" == "wiki.qaq.apelin.dev.app, wiki.qaq.apelin.dev.tweak, wiki.qaq.apelin.dev.cli, wiki.qaq.apelin.dev.preferences" ]] || {
    echo "error: Recommends must name exactly the four development extensions" >&2
    exit 65
}
if dpkg-deb -f "$temporary_deb" Depends Pre-Depends | grep -qE 'wiki\.qaq\.apelin\.(dev|agent-tools)\.'; then
    echo "error: the IDE must not depend on an extension; list development extensions under Recommends and leave agent tools out" >&2
    exit 65
fi
if dpkg-deb -f "$temporary_deb" Recommends Suggests | grep -qF 'wiki.qaq.apelin.agent-tools.'; then
    echo "error: the IDE recommends or suggests an agent tool extension" >&2
    exit 65
fi
contents="$(dpkg-deb --contents "$temporary_deb")"
grep -F ".$install_prefix/Applications/Apelin.app/$app_executable" <<<"$contents" >/dev/null
grep -F ".$install_prefix/Applications/Apelin.app/Licenses.json" <<<"$contents" >/dev/null
grep -F ".$install_prefix/Applications/Apelin.app/PlugIns/$widget_appex/$widget_executable" <<<"$contents" >/dev/null
for resource in "${app_resources[@]}"; do
    grep -F ".$install_prefix/Applications/Apelin.app/$resource/Info.plist" <<<"$contents" >/dev/null
done
grep -F ".$install_prefix/usr/libexec/apelind" <<<"$contents" >/dev/null
for worker in "${workers[@]}"; do
    grep -F ".$install_prefix/usr/libexec/apelin/$worker" <<<"$contents" >/dev/null
done
for resource in "${worker_resources[@]}"; do
    grep -F ".$install_prefix/usr/libexec/apelin/$resource/Info.plist" <<<"$contents" >/dev/null
done
for library in "${worker_runtime_libraries[@]}"; do
    grep -F ".$install_prefix/usr/libexec/apelin/$library" <<<"$contents" >/dev/null
done
grep -F ".$install_prefix/Library/LaunchDaemons/wiki.qaq.apelind.plist" <<<"$contents" >/dev/null
grep -F ".$install_prefix/etc/profile.d/wiki.qaq.apelin.sh" <<<"$contents" >/dev/null

mv -f "$temporary_deb" "$output_deb"
echo "Packaged Apelin ($flavor): $output_deb"
shasum -a 256 "$output_deb"
