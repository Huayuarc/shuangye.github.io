export THEOS ?= /var/mobile/theos

THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AkaraConnectivity AkaraPrefs

AkaraConnectivity_BUNDLE_EXTENSION = bundle
AkaraConnectivity_FILES = AkaraConnectivity.m AkaraConnectivityModuleContentViewController.m
AkaraConnectivity_INSTALL_PATH = /Library/ControlCenter/Bundles
AkaraConnectivity_RESOURCE_DIRS = AkaraConnectivityResources
AkaraConnectivity_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unguarded-availability-new -Wno-arc-performSelector-leaks
AkaraConnectivity_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore

AkaraPrefs_BUNDLE_EXTENSION = bundle
AkaraPrefs_FILES = AkaraPrefs.m
AkaraPrefs_INSTALL_PATH = /Library/PreferenceBundles
AkaraPrefs_RESOURCE_DIRS = AkaraPrefsResources
AkaraPrefs_CFLAGS = -fno-objc-arc -Wno-deprecated-declarations -Wno-unguarded-availability-new
AkaraPrefs_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
AkaraPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk

before-stage::
	mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences
	cp PreferenceLoaderResources/AkaraPrefs.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/AkaraPrefs.plist
