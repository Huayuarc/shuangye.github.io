#!/bin/zsh
# Makes the README and package banner, Documents/screenshots.jpg, from
# Template.fig: builds the app for an iPhone simulator, fills it with the demo
# conversations in demo-data.py, takes a screenshot of each, puts them into the
# template's slots (Banner.fig) and renders the frame. README.md says more.
#
#   Documents/Banner/make-banner.sh            # the "iPhone 18 Pro" simulator
#   SIMULATOR=<name or UDID> Documents/Banner/make-banner.sh
set -euo pipefail

HERE=${0:A:h}
ROOT=${HERE:h:h}
WORK=$ROOT/build/Banner
DERIVED=/private/tmp/apelin-banner-deriveddata
SIMULATOR=${SIMULATOR:-iPhone 18 Pro}
BUNDLE=wiki.qaq.apelin
# One screenshot per slot, in slot order: Screenshot 1 is the largest.
CHATS=("Frosted Dock" "Choosing a Toolchain" "Battery Health" "Heart Rate Chart"
    "Why Did SpringBoard Crash?" "Publish to My Repository")

mkdir -p "$WORK/screenshots"

# --- The app, for the simulator ----------------------------------------------
# A screenshot build only: Apelin ships no simulator build. The packages the
# device build resolved are reused when they are there.
if [[ -d /private/tmp/apelin-deriveddata/SourcePackages && ! -e $DERIVED/SourcePackages ]]; then
    mkdir -p "$DERIVED"
    ln -s /private/tmp/apelin-deriveddata/SourcePackages "$DERIVED/SourcePackages"
fi
xcodebuild -project "$ROOT/Apelin.xcodeproj" -scheme Apelin -configuration Debug \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$DERIVED/SourcePackages" \
    -skipMacroValidation -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO SUPPORTED_PLATFORMS="iphoneos iphonesimulator" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    build >"$WORK/xcodebuild.log" 2>&1 || { tail -20 "$WORK/xcodebuild.log"; exit 1; }
APP=$DERIVED/Build/Products/Debug-iphonesimulator/Apelin.app

# --- The simulator -------------------------------------------------------------
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
want = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if want in (d["udid"], d["name"]) and "iOS" in runtime:
            print(d["udid"], d["state"]); sys.exit()
sys.exit("no simulator named " + want)' "$SIMULATOR")
STATE=${UDID#* }
UDID=${UDID%% *}
cleanup() {
    xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
    xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
    xcrun simctl status_bar "$UDID" clear 2>/dev/null || true
    [[ $STATE == Booted ]] || xcrun simctl shutdown "$UDID" 2>/dev/null || true
}
trap cleanup EXIT
[[ $STATE == Booted ]] || xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 --dataNetwork wifi
xcrun simctl install "$UDID" "$APP"

# --- The conversations ---------------------------------------------------------
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
# The app's preferences, written through the simulator's cfprefsd: an edit
# to the plist on disk is overwritten by what cfprefsd holds.
PREFERENCES=$DATA/Library/Preferences/$BUNDLE
set_default() { xcrun simctl spawn "$UDID" defaults write "$PREFERENCES" "$@"; }
python3 "$HERE/demo-data.py" "$DATA/Documents/$BUNDLE" "$WORK/chats.json"
set_default onboarding.seenVersion -integer 1
set_default composer.reasoningEffort -string high
set_default composer.modelSelection -data "$(printf '%s' \
    '{"provider":"githubCopilot","model":"claude-opus-5.5","supportedEfforts":["low","high","max"]}' | xxd -p | tr -d '\n')"

screenshots=()
for title in "${CHATS[@]}"; do
    read -r id project < <(python3 -c 'import json, sys
chat = json.load(open(sys.argv[1]))[sys.argv[2]]
print(chat[0], chat[1] or "")' "$WORK/chats.json" "$title")
    # Quitting writes the app's own selection back; let it finish first.
    xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
    sleep 2
    set_default chat.selectedID -string "$id"
    if [[ -n $project ]]; then
        set_default chat.selectedProject -string "$project"
    else
        xcrun simctl spawn "$UDID" defaults delete "$PREFERENCES" chat.selectedProject 2>/dev/null || true
    fi
    xcrun simctl launch "$UDID" "$BUNDLE" -AppleLanguages "(en)" -AppleLocale en_US >/dev/null
    sleep 7
    shot="$WORK/screenshots/${#screenshots[@]}.png"
    # The whole screen, square: the display's rounded mask would leave
    # transparent corners inside the template's own, smaller ones.
    xcrun simctl io "$UDID" screenshot --mask=ignored "$shot" >/dev/null 2>&1
    # Opaque, so JPEG: a PNG of each made Banner.fig four times the size.
    sips -s format jpeg -s formatOptions 90 "$shot" --out "${shot%.png}.jpg" >/dev/null
    screenshots+=("${shot%.png}.jpg")
    echo "screenshot $(( ${#screenshots[@]} )): $title"
done

# --- The template and the banner ----------------------------------------------
# The icon from its source, not the icon set: those JPEGs are masked onto
# white, which shows inside the slot's corners. The export's own mask is the
# Icon slot's: 22.37 % corners, smoothed.
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
"$ICTOOL" "$ROOT/Documents/Icon/AppIcon.icon" --export-image --output-file "$WORK/icon.png" \
    --platform iOS --rendition Default --width 512 --height 512 --scale 2 >/dev/null
(cd "$HERE/Tool" && pnpm install --frozen-lockfile --silent)
node "$HERE/Tool/fill-slots.mjs" "$HERE/Template.fig" "$HERE/Banner.fig" "$WORK/fill" "$WORK/icon.png" "${screenshots[@]}"
swiftc -O "$HERE/Tool/snapshot.swift" -o "$WORK/snapshot"
# Rendered at twice the frame's size and scaled down to it: the slots are
# turned 20°, and a 1x render resamples the screenshots soft. A JPEG the
# frame's size is what the repository keeps, as Fila keeps its banner.
read -r width height < <(node "$HERE/Tool/render.mjs" "$WORK/fill/fig" "$WORK/render/index.html")
"$WORK/snapshot" "$WORK/render/index.html" "$WORK/banner@2x.png" "$width" "$height" 2
sips -s format jpeg -s formatOptions 85 -Z "$width" "$WORK/banner@2x.png" --out "$ROOT/Documents/screenshots.jpg" >/dev/null

# Banner.fig: the filled template, with Figma's thumbnail of it.
sips -s format png -z 200 400 "$WORK/banner@2x.png" --out "$WORK/fill/fig/thumbnail.png" >/dev/null
rm -f "$HERE/Banner.fig"
(cd "$WORK/fill/fig" && zip -0 -q -r "$HERE/Banner.fig" canvas.fig meta.json thumbnail.png images)
echo "wrote Documents/screenshots.jpg and Documents/Banner/Banner.fig ($WORK/banner@2x.png at full size)"
