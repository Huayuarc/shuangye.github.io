export THEOS ?= /var/mobile/theos
export PATH := $(THEOS)/bin:$(PATH)
FINALPACKAGE = 1
export TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk

ifeq ($(SCHEME),roothide)
export THEOS_PACKAGE_SCHEME := roothide
else ifeq ($(THEOS_PACKAGE_SCHEME),)
export THEOS_PACKAGE_SCHEME := rootless
endif

export ARCHS = arm64 arm64e
ROOTHIDE_LDFLAGS = -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide

TWEAK_NAME = CPUthermal CPUthermalForeground

CPUthermal_FILES = Tweak.x
CPUthermal_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE -fvisibility=hidden -DCPUTHERMAL_STRIP_LOGS=1
CPUthermal_LDFLAGS += -Wl,-x -Wl,-dead_strip
CPUthermal_FRAMEWORKS = Foundation CoreFoundation
CPUthermal_LIBRARIES = substrate

CPUthermalForeground_FILES = ForegroundMode.xm
CPUthermalForeground_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE -fvisibility=hidden -DCPUTHERMAL_STRIP_LOGS=1
CPUthermalForeground_LDFLAGS += -Wl,-x -Wl,-dead_strip
CPUthermalForeground_FRAMEWORKS = Foundation UIKit
CPUthermalForeground_LIBRARIES = substrate

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermal_LDFLAGS += $(ROOTHIDE_LDFLAGS)
CPUthermalForeground_LDFLAGS += $(ROOTHIDE_LDFLAGS)
endif
include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = CPUthermalSettings
CPUthermalSettings_FILES = Settings/FRootListController.m Settings/CPUthermalAppListController.m
CPUthermalSettings_INSTALL_PATH = /Library/PreferenceBundles
CPUthermalSettings_CFLAGS = -fobjc-arc -Iinclude
CPUthermalSettings_CODESIGN_FLAGS = -SSettings/Settings.entitlements
CPUthermalSettings_FRAMEWORKS = UIKit Foundation
CPUthermalSettings_PRIVATE_FRAMEWORKS = Preferences
CPUthermalSettings_LDFLAGS += -Wl,-undefined,dynamic_lookup
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalSettings_LDFLAGS += $(ROOTHIDE_LDFLAGS)
endif
include $(THEOS_MAKE_PATH)/bundle.mk

before-all::
	$(ECHO_NOTHING)if [ "$(THEOS_PACKAGE_SCHEME)" = "rootless" ]; then sed 's|@JBROOT@|/var/jb|g' scripts/postinst.in > layout/DEBIAN/postinst; sed 's|@JBROOT@|/var/jb|g' scripts/prerm.in > layout/DEBIAN/prerm; else sed 's|@JBROOT@||g' scripts/postinst.in > layout/DEBIAN/postinst; sed 's|@JBROOT@||g' scripts/prerm.in > layout/DEBIAN/prerm; fi$(ECHO_END)
	$(ECHO_NOTHING)chmod 0755 layout/DEBIAN/postinst layout/DEBIAN/prerm$(ECHO_END)

before-package::
	$(ECHO_NOTHING)chmod 0755 layout/DEBIAN/postinst layout/DEBIAN/prerm$(ECHO_END)

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/CPUthermalSettings.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Info.plist Settings/Root.plist Settings/icon.png Settings/icon@2x.png Settings/icon@3x.png "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
