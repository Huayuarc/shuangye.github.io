#!/bin/bash
# Install a built .deb onto a jailbroken device over SSH; optionally relaunch.
#
# A phone on a cable is reached through usbmuxd: `iproxy 2333 22` forwards a
# local port to its sshd. A vphone VM answers on its own address, port 22
# (`make vphone`, which finds it). `Scripts/device.py` runs console scripts there.
#
#   Scripts/install-device.sh build/Packages/wiki.qaq.apelin_0.1.0_iphoneos-arm64.deb
#
# With --app it puts a built Apelin.app over the installed one instead
# (`make vphone-app`, the inner loop while working on the app): signed as
# the packager signs it, root-owned, so the daemon still takes it as its
# peer. The daemon, the workers and dpkg's record stay as the last package
# left them, so a change outside the app, a file added to or removed from
# the bundle that dpkg should know of, or anything shipped, needs a package.
#
#   Scripts/install-device.sh --app build/…/Release-iphoneos/Apelin.app --launch
#
# Overridable: DEVICE_HOST, DEVICE_PORT, DEVICE_USER, DEVICE_PASSWORD.
# Without DEVICE_PASSWORD the usual ssh key path is used.

set -euo pipefail

mode=package
if [[ "${1:-}" == --app ]]; then
    mode=app
    shift
fi
if [[ $# -lt 1 || $# -gt 2 || ($# -eq 2 && "$2" != --launch) ]]; then
    echo "usage: install-device.sh <package.deb> [--launch]" >&2
    echo "       install-device.sh --app <Apelin.app> [--launch]" >&2
    exit 64
fi
package="$1"
launch=false
[[ "${2:-}" == --launch ]] && launch=true
host="${DEVICE_HOST:-127.0.0.1}"
port="${DEVICE_PORT:-2333}"
user="${DEVICE_USER:-mobile}"
password="${DEVICE_PASSWORD:-}"

if [[ $mode == app ]]; then
    test -f "$package/Info.plist" || { echo "error: $package is not an app bundle" >&2; exit 66; }
    command -v ldid >/dev/null || { echo "error: ldid is not installed; install it with your preferred package manager" >&2; exit 69; }
else
    test -f "$package" || { echo "error: $package does not exist" >&2; exit 66; }
fi

# Host keys change every time a VM guest is rebuilt, and this is a loopback
# port to a device we just built for — recording them would only produce a
# mismatch to clear by hand later.
ssh_options=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
)

if [ -n "$password" ]; then
    command -v sshpass >/dev/null || { echo "error: DEVICE_PASSWORD is set but sshpass is not installed; install it with your preferred package manager, or unset DEVICE_PASSWORD" >&2; exit 69; }
    # Some guests refuse plain password authentication and accept only
    # keyboard-interactive, which sshpass answers the same way; an agent's
    # keys are left out so they cannot use up the attempts first.
    ssh_options+=(
        -o PubkeyAuthentication=no
        -o PreferredAuthentications=keyboard-interactive,password
        -o NumberOfPasswordPrompts=1
    )
    # Through the environment, never `-p`: an argument is on the process list
    # for anyone on the Mac to read until sshpass overwrites it.
    run_ssh() { SSH_AUTH_SOCK= SSHPASS="$password" sshpass -e ssh "${ssh_options[@]}" -p "$port" "$user@$host" "$@"; }
else
    run_ssh() { ssh "${ssh_options[@]}" -p "$port" "$user@$host" "$@"; }
fi

if ! nc -z "$host" "$port" 2>/dev/null; then
    echo "error: nothing is listening on $host:$port." >&2
    echo "       Start the usbmuxd forward first:  iproxy $port 22" >&2
    exit 69
fi

# Quote one argument for the remote POSIX shell, including embedded quotes.
shell_quote() {
    local quote="'" escaped="'\\''"
    printf "'%s'" "${1//$quote/$escaped}"
}

# A non-login ssh shell on a jailbroken guest can come up with nothing but
# /usr/bin:/bin — the vphone's does — and sudo and dpkg live in
# the bootstrap. Added rather than substituted, and inside the remote shell as
# well because sudo may impose its own secure_path. A relocated roothide
# bootstrap is not guessable from here; its own profile puts it on PATH.
bootstrap_bin='/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin'
remote_path="PATH=\"\$PATH:$bootstrap_bin\""

# The same PATH for the unprivileged calls — killall, uiopen and the upload.
run_remote() {
    run_ssh "$remote_path; export PATH; $1"
}

# Keep the password on sudo's stdin, never in the remote command string.
run_sudo() {
    local command="sh -c $(shell_quote "$remote_path; export PATH; $1")"
    if [ -n "$password" ]; then
        printf '%s\n' "$password" | run_ssh "$remote_path sudo -S -p '' $command"
    else
        run_ssh "$remote_path sudo $command"
    fi
}

remote_directory=
staging=
cleanup_upload() {
    local status=0
    if [ -n "$remote_directory" ]; then
        # The new bundle only, never Apelin.app.previous: that is the
        # installed app, left there by a swap that could not be undone.
        run_sudo "rm -rf $(shell_quote "${remote_directory:?}/Apelin.app") && rm -f $(shell_quote "$remote_directory/package.deb") $(shell_quote "$remote_directory/app.tar") && rmdir $(shell_quote "$remote_directory")" || {
            echo "error: could not remove installation temporary: $remote_directory" >&2
            status=1
        }
    fi
    if [ -n "$staging" ]; then
        rm -rf -- "${staging:?}"
    fi
    return $status
}
trap cleanup_upload EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ $mode == app ]]; then
    # The packager's signing, without its stripping and path checks: every
    # embedded library ad hoc, the widget extension with its entitlements,
    # then the executable with its own.
    staging="$(mktemp -d)"
    /usr/bin/ditto "$package" "$staging/Apelin.app"
    shopt -s nullglob
    embedded=("$staging/Apelin.app/Frameworks"/*.dylib "$staging/Apelin.app/Frameworks"/*.framework)
    shopt -u nullglob
    for library in ${embedded[@]+"${embedded[@]}"}; do
        if [[ -d "$library" ]]; then
            rm -rf -- "${library:?}/_CodeSignature"
            library="$library/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$library/Info.plist")"
        fi
        ldid -S -Cadhoc "$library"
    done
    packaging="$(cd "$(dirname "$0")/.." && pwd)/Packaging"
    widget="$staging/Apelin.app/PlugIns/ApelinWidgets.appex"
    if [[ -d "$widget" ]]; then
        rm -rf -- "${widget:?}/_CodeSignature"
        ldid -S"$packaging/ApelinWidgets.entitlements" -Cadhoc \
            "$widget/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$widget/Info.plist")"
    fi
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$staging/Apelin.app/Info.plist")"
    ldid -S"$packaging/Apelin.entitlements" -Cadhoc "$staging/Apelin.app/$executable"
fi

# This installer updates an existing Apelin installation. Derive its actual
# bootstrap from dpkg instead of guessing a rootless or roothide prefix.
remote_directory="$(run_sudo '
    set -eu
    if ! daemon="$(dpkg -L wiki.qaq.apelin | grep "/usr/libexec/apelind$")" || [ ! -f "$daemon" ]; then
        echo "error: cannot locate the installed Apelin daemon; install Apelin before using this updater" >&2
        exit 1
    fi
    case "$daemon" in /*) ;; *) echo "error: installed Apelin daemon path is not absolute" >&2; exit 1 ;; esac
    install_root="${daemon%/usr/libexec/apelind}"
    install_root="$(cd -P "${install_root:-/}" && pwd -P)"
    directory="$(mktemp -d "${install_root%/}/.apelin-install.XXXXXXXX")"
    cleanup() { rmdir "$directory"; }
    trap cleanup EXIT
    chown "${SUDO_UID:?}:${SUDO_GID:?}" "$directory"
    chmod 0700 "$directory"
    printf "%s\n" "$directory"
    trap - EXIT
')"
# Streamed over the ssh session rather than scp'd: scp speaks sftp now, and a
# jailbroken guest's sftp-server lives in the bootstrap where the system sshd
# does not look for it. The destination is the temporary this script just made
# and chowned to this user.
if [[ $mode == app ]]; then
    echo "==> copying Apelin.app to $user@$host:$port"
    # No AppleDouble files, extended attributes or flags: the device's tar
    # would unpack them as files or warn about every header.
    COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --no-acls --no-fflags -C "$staging" -cf - Apelin.app |
        run_remote "cat > $(shell_quote "$remote_directory/app.tar")"
else
    remote_package="$remote_directory/package.deb"
    echo "==> copying $(basename "$package") to $user@$host:$port"
    run_remote "cat > $(shell_quote "$remote_package")" <"$package"
fi

# Let app-owned work finish cleanup before replacing its executable. An app
# replaced under a running copy would only offer to quit.
if $launch || [[ $mode == app ]]; then
    run_remote 'if killall -0 Apelin 2>/dev/null; then
        killall -TERM Apelin || exit
        attempts=0
        while killall -0 Apelin 2>/dev/null; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 20 ]; then echo "error: Apelin did not quit; close it on the device and try again" >&2; exit 1; fi
            sleep 0.25
        done
    fi'
fi

echo "==> installing"
if [[ $mode == app ]]; then
    # Root's, and writable by root alone, as the package leaves it: the
    # daemon refuses a peer whose executable is anything else. The old bundle
    # goes aside by a rename on the same volume and comes back if the new
    # one cannot take its place.
    run_sudo "directory=$(shell_quote "$remote_directory"); "'set -eu
        app="$(dpkg -L wiki.qaq.apelin | grep "/Applications/Apelin.app$")"
        cd "$directory"
        tar -xf app.tar
        rm -f app.tar
        chown -R 0:0 Apelin.app
        chmod -R u=rwX,go=rX Apelin.app
        mv "$app" Apelin.app.previous
        mv Apelin.app "$app" || { mv Apelin.app.previous "$app"; exit 1; }
        rm -rf Apelin.app.previous'
else
    # Irisin's installer (`irisin-cli install`, Irisin's helper underneath),
    # never apt or dpkg: both are on their way out. The package's postinst
    # boots the daemon (`launchctl bootstrap system`); uikittools triggers
    # register the app with SpringBoard. Neither step is duplicated here.
    #
    # The password reaches `sudo -S` down the ssh session's own stdin and is never
    # written into the remote command line. Spelling it into a quoted string there
    # would make a password containing a quote — or anything else a shell reads —
    # into remote code execution as root, which is a peculiar way to lose a device
    # you were installing an IDE onto.
    run_sudo "irisin-cli install --yes $(shell_quote "$remote_package")"
fi

echo "==> installed; removing the copy"
cleanup_upload
remote_directory=
staging=

# A package manager's own UI re-registers an upgrade with LaunchServices; an
# install from a file over an installed copy may not, and SpringBoard keeps reading the
# previous build's Info.plist from the record. Register this bundle by its
# path, which is what uikittools' trigger would not do for an installed app.
echo "==> registering the app"
run_sudo 'app="$(dpkg -L wiki.qaq.apelin | grep "/Applications/Apelin.app$")" && uicache -p "$app"'

if $launch; then
    echo "==> opening Apelin"
    run_remote "uiopen --bundleid wiki.qaq.apelin"
fi
