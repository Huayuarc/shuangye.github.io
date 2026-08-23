TARGET := iphone:clang:16.5:15.0
FINALPACKAGE = 1
INSTALL_TARGET_PROCESSES = SpringBoard Preferences
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ARCHS = arm64e
else
ARCHS = arm64
endif
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = EvanescoTweak
EvanescoTweak_FILES = Tweak.xm
EvanescoTweak_FRAMEWORKS = UIKit Foundation CoreFoundation
EvanescoTweak_CFLAGS = -fobjc-arc -fvisibility=hidden
EvanescoTweak_LDFLAGS = -Wl,-x -Wl,-dead_strip
BUNDLE_NAME = Evanesco
Evanesco_FILES = prefs/EvanescoRootController.m
Evanesco_FRAMEWORKS = UIKit Foundation CoreFoundation
Evanesco_CFLAGS = -fobjc-arc
Evanesco_LDFLAGS = -Wl,-undefined,dynamic_lookup
Evanesco_INSTALL_PATH = /Library/PreferenceBundles
Evanesco_RESOURCE_DIRS = prefs/Resources
BUNDLE_NAME += evanescocc
evanescocc_FILES = cc/EvanescoCC.m
evanescocc_FRAMEWORKS = UIKit Foundation CoreFoundation
evanescocc_PRIVATE_FRAMEWORKS = ControlCenterUIKit
evanescocc_CFLAGS = -fobjc-arc
evanescocc_INSTALL_PATH = /Library/ControlCenter/Bundles
evanescocc_RESOURCE_DIRS = cc/Resources
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
