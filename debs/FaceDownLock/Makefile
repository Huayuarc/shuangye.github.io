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

TWEAK_NAME = FaceDownLock
FaceDownLock_FILES = Tweak.xm
FaceDownLock_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -fvisibility=hidden -DFACEDOWNLOCK_STRIP_LOGS=1
FaceDownLock_LDFLAGS += -Wl,-x -Wl,-dead_strip
FaceDownLock_FRAMEWORKS = Foundation UIKit CoreFoundation
FaceDownLock_LIBRARIES = substrate
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
FaceDownLock_LDFLAGS += $(ROOTHIDE_LDFLAGS)
endif
include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = FaceDownLockSettings
FaceDownLockSettings_FILES = Settings/FDLRootListController.m
FaceDownLockSettings_INSTALL_PATH = /Library/PreferenceBundles
FaceDownLockSettings_CFLAGS = -fobjc-arc -Iinclude
FaceDownLockSettings_CODESIGN_FLAGS = -SSettings/Settings.entitlements
FaceDownLockSettings_FRAMEWORKS = Foundation UIKit
FaceDownLockSettings_PRIVATE_FRAMEWORKS = Preferences
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
FaceDownLockSettings_LDFLAGS += $(ROOTHIDE_LDFLAGS) -Wl,-undefined,dynamic_lookup
endif
include $(THEOS_MAKE_PATH)/bundle.mk

before-all::
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst" "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"$(ECHO_END)

before-package::
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst" "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"$(ECHO_END)

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/FaceDownLockSettings.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Info.plist Settings/Root.plist Settings/icon.png Settings/icon@2x.png Settings/icon@3x.png "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/FaceDownLockSettings.bundle/"$(ECHO_END)
