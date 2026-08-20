TARGET := iphone:clang:latest:15.0
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ARCHS = arm64e
else
ARCHS = arm64
endif
FINALPACKAGE = 1
INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AdSkipSelector
AdSkipSelector_FILES = Tweak.xm
AdSkipSelector_CFLAGS = -fobjc-arc -fvisibility=hidden -DADSKIP_STRIP_LOGS=1
AdSkipSelector_LDFLAGS = -Wl,-x -Wl,-dead_strip
AdSkipSelector_FRAMEWORKS = UIKit Foundation CoreFoundation

BUNDLE_NAME = AdSkipPrefs
AdSkipPrefs_FILES = prefs/ASPAppListController.m
AdSkipPrefs_CFLAGS = -fobjc-arc -fvisibility=hidden
AdSkipPrefs_LDFLAGS = -Wl,-x -Wl,-dead_strip
AdSkipPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
AdSkipPrefs_INSTALL_PATH = /Library/PreferenceBundles
AdSkipPrefs_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

before-package::
	@mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences
	@cp prefs/entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/AdSkipPrefs.plist
