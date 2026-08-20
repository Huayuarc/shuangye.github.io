TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
ARCHS = arm64
else
ARCHS = arm64e
endif

include $(THEOS)/makefiles/common.mk

# TWEAK_NAME marker is used by repository CI project discovery.
TWEAK_NAME = VPNControllerHook
VPNControllerHook_FILES = VPNControllerHook.m
VPNControllerHook_FRAMEWORKS = Foundation CoreFoundation
VPNControllerHook_PRIVATE_FRAMEWORKS = Preferences
VPNControllerHook_CFLAGS = -fobjc-arc -fvisibility=hidden
VPNControllerHook_LDFLAGS = -Wl,-x -Wl,-dead_strip

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = VPNNodeSelector
VPNNodeSelector_FILES = VPNNodeModule.m VPNNodeViewController.m VPNBridge.m
VPNNodeSelector_FRAMEWORKS = UIKit Foundation NetworkExtension
VPNNodeSelector_PRIVATE_FRAMEWORKS = ControlCenterUIKit
VPNNodeSelector_CFLAGS = -fobjc-arc -fvisibility=hidden
VPNNodeSelector_LDFLAGS = -Wl,-x -Wl,-dead_strip
VPNNodeSelector_INSTALL_PATH = /Library/ControlCenter/Bundles
VPNNodeSelector_RESOURCE_DIRS = resources

FINALPACKAGE = 1
include $(THEOS_MAKE_PATH)/bundle.mk
