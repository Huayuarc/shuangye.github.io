export THEOS ?= /var/mobile/theos
export PATH := $(THEOS)/bin:$(PATH)
FINALPACKAGE = 1
export TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk
export ARCHS = arm64 arm64e

ifeq ($(SCHEME),roothide)
export THEOS_PACKAGE_SCHEME := roothide
else ifeq ($(THEOS_PACKAGE_SCHEME),)
export THEOS_PACKAGE_SCHEME := rootless
endif

ROOTHIDE_LDFLAGS = -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide

TWEAK_NAME = CC26Loader
CC26Loader_FILES = Loader.m
CC26Loader_CFLAGS = -fobjc-arc -fvisibility=hidden
CC26Loader_LDFLAGS += -Wl,-x -Wl,-dead_strip
CC26Loader_FRAMEWORKS = Foundation UIKit
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CC26Loader_LDFLAGS += $(ROOTHIDE_LDFLAGS)
endif
include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = CC26Settings
CC26Settings_FILES = prefs/CC26RootListController.m
CC26Settings_INSTALL_PATH = /Library/PreferenceBundles
CC26Settings_CFLAGS = -fobjc-arc
CC26Settings_CODESIGN_FLAGS = -Sprefs/Settings.entitlements
CC26Settings_FRAMEWORKS = Foundation UIKit
CC26Settings_PRIVATE_FRAMEWORKS = Preferences
CC26Settings_RESOURCE_DIRS = prefs/Resources
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CC26Settings_LDFLAGS += $(ROOTHIDE_LDFLAGS) -Wl,-undefined,dynamic_lookup
endif
include $(THEOS_MAKE_PATH)/bundle.mk

before-all::
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst" "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"$(ECHO_END)
	$(ECHO_NOTHING)rm -f "$(THEOS_PROJECT_DIR)/CC26Core.dylib"$(ECHO_END)
	$(ECHO_NOTHING)python3 "$(THEOS_PROJECT_DIR)/patch_cc26.py" "$(THEOS_PROJECT_DIR)/baseline/CC26.dylib" "$(THEOS_PROJECT_DIR)/CC26Core.dylib"$(ECHO_END)

before-package::
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst" "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"$(ECHO_END)

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries" "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences" "$(THEOS_STAGING_DIR)/Library/CC26"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/CC26Core.dylib" "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/CC26Core.dylib"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/prefs/Resources/entry.plist" "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/CC26Settings.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/CC26-icon.png" "$(THEOS_STAGING_DIR)/Library/CC26/icon.png"$(ECHO_END)
	$(ECHO_NOTHING)ldid -S "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/CC26Core.dylib"$(ECHO_END)
	$(ECHO_NOTHING)if [ "$(THEOS_PACKAGE_SCHEME)" = "roothide" ]; then ln -sf /usr/lib/DynamicPatches/AutoPatches.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/CC26Core.dylib.roothidepatch"; fi$(ECHO_END)

after-clean::
	$(ECHO_NOTHING)rm -f "$(THEOS_PROJECT_DIR)/CC26Core.dylib"$(ECHO_END)
