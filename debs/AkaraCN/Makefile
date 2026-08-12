ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AkaraCN
AkaraCN_FILES = Tweak.xm
AkaraCN_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-deprecated-declarations
AkaraCN_FRAMEWORKS = UIKit Foundation MediaPlayer AVFoundation
AkaraCN_PRIVATE_FRAMEWORKS = MediaRemote
AkaraCN_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = AkaraCNPrefs
AkaraCNPrefs_FILES = AKRRootListController.m
AkaraCNPrefs_FRAMEWORKS = UIKit
AkaraCNPrefs_PRIVATE_FRAMEWORKS = Preferences
AkaraCNPrefs_INSTALL_PATH = /Library/PreferenceBundles
AkaraCNPrefs_RESOURCE_FILES = BundleInfo.plist
AkaraCNPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences
	mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceBundles/AkaraCNPrefs.bundle
	cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/AkaraCN.plist
	cp BundleInfo.plist $(THEOS_STAGING_DIR)/Library/PreferenceBundles/AkaraCNPrefs.bundle/Info.plist

after-install::
	install.exec "killall -9 SpringBoard"
