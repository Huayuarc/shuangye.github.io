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
SneakySupport_FILES = Support.xm SCPaths.m
SneakySupport_CFLAGS = -fobjc-arc
SneakySupport_FRAMEWORKS = Foundation AVFoundation

TWEAK_NAME += SneakyCamCCRegistration
SneakyCamCCRegistration_FILES = CCRegistration.xm SCPaths.m
SneakyCamCCRegistration_CFLAGS = -fobjc-arc -fvisibility=hidden
SneakyCamCCRegistration_FRAMEWORKS = Foundation CoreFoundation
SneakyCamCCRegistration_LIBRARIES = substrate
SneakyCamCCRegistration_LDFLAGS = -Wl,-x -Wl,-dead_strip

BUNDLE_NAME = SneakyCamSettings SneakyCamCCToggle SneakyCamCCPhoto SneakyCamCCVideo
SneakyCamSettings_FILES = Preferences/SCRootListController.m SCPaths.m
SneakyCamSettings_CFLAGS = -fobjc-arc
SneakyCamSettings_FRAMEWORKS = UIKit Foundation
SneakyCamSettings_PRIVATE_FRAMEWORKS = Preferences
SneakyCamSettings_INSTALL_PATH = /Library/PreferenceBundles
SneakyCamSettings_RESOURCE_DIRS = Preferences/Resources

# 原总开关 CC 模块
SneakyCamCCToggle_FILES = ControlCenter/SneakyCamCCToggle.m SCPaths.m
SneakyCamCCToggle_CFLAGS = -fobjc-arc
SneakyCamCCToggle_FRAMEWORKS = Foundation UIKit
SneakyCamCCToggle_PRIVATE_FRAMEWORKS = ControlCenterUIKit
SneakyCamCCToggle_INSTALL_PATH = /Library/ControlCenter/Bundles
SneakyCamCCToggle_RESOURCE_DIRS = ControlCenter/resourcesToggle

# 拍照 CC 开关模块
SneakyCamCCPhoto_FILES = ControlCenter/SneakyCamCCPhoto.m SCPaths.m
SneakyCamCCPhoto_CFLAGS = -fobjc-arc
SneakyCamCCPhoto_FRAMEWORKS = Foundation UIKit
SneakyCamCCPhoto_PRIVATE_FRAMEWORKS = ControlCenterUIKit
SneakyCamCCPhoto_INSTALL_PATH = /Library/ControlCenter/Bundles
SneakyCamCCPhoto_RESOURCE_DIRS = ControlCenter/resourcesPhoto

# 录像 CC 开关模块
SneakyCamCCVideo_FILES = ControlCenter/SneakyCamCCVideo.m SCPaths.m
SneakyCamCCVideo_CFLAGS = -fobjc-arc
SneakyCamCCVideo_FRAMEWORKS = Foundation UIKit
SneakyCamCCVideo_PRIVATE_FRAMEWORKS = ControlCenterUIKit
SneakyCamCCVideo_INSTALL_PATH = /Library/ControlCenter/Bundles
SneakyCamCCVideo_RESOURCE_DIRS = ControlCenter/resourcesVideo

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

before-package::
	core=$$(find $(THEOS_STAGING_DIR) -name 'SneakyCamCore.dylib' -type f | head -1); if [ -n "$$core" ]; then mv "$$core" "$${core%/*}/SneakyCam.dylib"; fi
	find $(THEOS_STAGING_DIR) -name 'SneakyCamCore.plist' -type f -delete
	find $(THEOS_STAGING_DIR) \( -name '*.dylib' -o -path '*/SneakyCamSettings.bundle/SneakyCamSettings' -o -path '*/SneakyCamCCToggle.bundle/SneakyCamCCToggle' -o -path '*/SneakyCamCCPhoto.bundle/SneakyCamCCPhoto' -o -path '*/SneakyCamCCVideo.bundle/SneakyCamCCVideo' \) -type f | while read f; do ldid -S "$$f" 2>/dev/null || true; done

after-install::
	install.exec "killall -9 SpringBoard mediaserverd 2>/dev/null || true"
