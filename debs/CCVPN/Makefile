TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
ARCHS = arm64
else
ARCHS = arm64e
endif

include $(THEOS)/makefiles/common.mk

# TWEAK_NAME marker: GitHub CI 使用它识别 Theos 工程；实际产物只有 CCVPN Bundle。
BUNDLE_NAME = CCVPN
CCVPN_FILES = CCVPNModule.m CCVPNModuleViewController.m
CCVPN_FRAMEWORKS = UIKit Foundation NetworkExtension
CCVPN_PRIVATE_FRAMEWORKS = ControlCenterUIKit
CCVPN_CFLAGS = -fobjc-arc -fvisibility=hidden
CCVPN_LDFLAGS = -Wl,-x -Wl,-dead_strip
CCVPN_INSTALL_PATH = /Library/ControlCenter/Bundles
CCVPN_RESOURCE_DIRS = resources

FINALPACKAGE = 1
include $(THEOS_MAKE_PATH)/bundle.mk
