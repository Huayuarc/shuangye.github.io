ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ARCHS = arm64e
else
ARCHS = arm64 arm64e
endif
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SneakyCamCore
SneakyCamCore_FILES = Tweak.xm SCCaptureManager.m SCPaths.m
SneakyCamCore_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
SneakyCamCore_FRAMEWORKS = Foundation UIKit AVFoundation Photos AudioToolbox CoreMedia

TWEAK_NAME += SneakySupport
SneakySupport_FILES = Support.xm
SneakySupport_CFLAGS = -fobjc-arc
SneakySupport_FRAMEWORKS = Foundation AVFoundation

BUNDLE_NAME = SneakyCam SneakyCamCC
SneakyCam_FILES = Preferences/SCRootListController.m SCPaths.m
SneakyCam_CFLAGS = -fobjc-arc
SneakyCam_FRAMEWORKS = UIKit Foundation
SneakyCam_PRIVATE_FRAMEWORKS = Preferences
SneakyCam_INSTALL_PATH = /Library/PreferenceBundles
SneakyCam_RESOURCE_DIRS = Preferences/Resources

SneakyCamCC_FILES = ControlCenter/SneakyCamCCModule.m ControlCenter/SneakyCamCCModuleViewController.m SCPaths.m
SneakyCamCC_CFLAGS = -fobjc-arc
SneakyCamCC_FRAMEWORKS = Foundation UIKit
SneakyCamCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
SneakyCamCC_INSTALL_PATH = /Library/ControlCenter/Bundles
SneakyCamCC_RESOURCE_DIRS = ControlCenter/resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

before-package::
	core=$$(find $(THEOS_STAGING_DIR) -name 'SneakyCamCore.dylib' -type f | head -1); if [ -n "$$core" ]; then mv "$$core" "$${core%/*}/SneakyCam.dylib"; fi
	find $(THEOS_STAGING_DIR) -name 'SneakyCamCore.plist' -type f -delete
	find $(THEOS_STAGING_DIR) \( -name '*.dylib' -o -path '*/SneakyCam.bundle/SneakyCam' -o -path '*/SneakyCamCC.bundle/SneakyCamCC' \) -type f | while read f; do ldid -S "$$f" 2>/dev/null || true; done

after-install::
	install.exec "killall -9 SpringBoard mediaserverd 2>/dev/null || true"
