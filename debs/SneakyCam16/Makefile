ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ARCHS = arm64e
else
ARCHS ?= arm64
endif
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SneakyCam16
SneakyCam16_FILES = Tweak.xm SCCaptureManager.m SCPaths.m
SneakyCam16_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
SneakyCam16_FRAMEWORKS = Foundation UIKit AVFoundation Photos AudioToolbox CoreMedia

TWEAK_NAME += SneakySupport16
SneakySupport16_FILES = Support.xm
SneakySupport16_CFLAGS = -fobjc-arc
SneakySupport16_FRAMEWORKS = Foundation AVFoundation

BUNDLE_NAME = SneakyCamPrefs
SneakyCamPrefs_FILES = Preferences/SCRootListController.m SCPaths.m
SneakyCamPrefs_CFLAGS = -fobjc-arc
SneakyCamPrefs_FRAMEWORKS = UIKit Foundation
SneakyCamPrefs_PRIVATE_FRAMEWORKS = Preferences
SneakyCamPrefs_INSTALL_PATH = /Library/PreferenceBundles
SneakyCamPrefs_RESOURCE_DIRS = Preferences/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

before-package::
	find $(THEOS_STAGING_DIR) -name '*.dylib' -o -name 'SneakyCamPrefs' | while read f; do ldid -S "$$f" 2>/dev/null || true; done

after-install::
	install.exec "killall -9 SpringBoard mediaserverd 2>/dev/null || true"
