TARGET := iphone:clang:16.5:15.0
FINALPACKAGE = 1
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ARCHS = arm64e
else
ARCHS = arm64
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = EvanescoModern
EvanescoModern_FILES = Tweak.xm
EvanescoModern_FRAMEWORKS = UIKit Foundation CoreFoundation
EvanescoModern_CFLAGS = -fobjc-arc -fvisibility=hidden
EvanescoModern_LDFLAGS = -Wl,-x -Wl,-dead_strip

BUNDLE_NAME = EvanescoPrefs
EvanescoPrefs_FILES = prefs/EvanescoRootController.m
EvanescoPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
EvanescoPrefs_CFLAGS = -fobjc-arc
EvanescoPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
EvanescoPrefs_INSTALL_PATH = /Library/PreferenceBundles
EvanescoPrefs_RESOURCE_DIRS = prefs/Resources

BUNDLE_NAME += EvanescoCC
EvanescoCC_FILES = cc/EvanescoCC.m
EvanescoCC_FRAMEWORKS = UIKit Foundation CoreFoundation
EvanescoCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
EvanescoCC_CFLAGS = -fobjc-arc
EvanescoCC_INSTALL_PATH = /Library/ControlCenter/Bundles
EvanescoCC_RESOURCE_DIRS = cc/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
