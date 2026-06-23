#!/bin/sh

if [ -d /var/jb ]; then
    PREFIX=/var/jb
    MOBILE_ROOT=/var/jb/var/mobile
else
    PREFIX=
    MOBILE_ROOT=/var/mobile
fi

SUPPORT_DIR="$PREFIX/Library/Application Support/Akara"
CC_DIR="$MOBILE_ROOT/Library/ControlCenter"
PREF_DIR="$MOBILE_ROOT/Library/Preferences"

mkdir -p "$CC_DIR" "$PREF_DIR"
cp "$SUPPORT_DIR/ModuleConfiguration_Akara.plist" "$CC_DIR/"

for name in \
    com.huayuarc.akara.providedakaramodule.0 \
    com.huayuarc.akara.providedakaramodule.1 \
    com.huayuarc.akara.providedakaraverticalmodule.0
 do
    cp "$SUPPORT_DIR/$name.plist" "$PREF_DIR/" 2>/dev/null || true
 done
