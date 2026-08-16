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

BUNDLE_NAME = SneakyCam SneakyCamCCToggle SneakyCamCCPhoto SneakyCamCCVideo
SneakyCam_FILES = Preferences/SCRootListController.m SCPaths.m
SneakyCam_CFLAGS = -fobjc-arc
SneakyCam_FRAMEWORKS = UIKit Foundation
SneakyCam_PRIVATE_FRAMEWORKS = Preferences
SneakyCam_INSTALL_PATH = /Library/PreferenceBundles
SneakyCam_RESOURCE_DIRS = Preferences/Resources

# 原总开关 CC 模块
SneakyCamCCToggle_FILES = ControlCenter/SneakyCamCCToggle.m ControlCenter/SneakyCamCCCommon.m SCPaths.m
SneakyCamCCToggle_CFLAGS = -fobjc-arc -DSC_CC_VC_CLASS=SneakyCamCCToggleViewController
SneakyCamCCToggle_FRAMEWORKS = Foundation UIKit
SneakyCamCCToggle_PRIVATE_FRAMEWORKS = ControlCenterUIKit
SneakyCamCCToggle_INSTALL_PATH = /Library/ControlCenter/Bundles
SneakyCamCCToggle_RESOURCE_DIRS = ControlCenter/resourcesToggle

# 拍照 CC 开关模块
SneakyCamCCPhoto_FILES = ControlCenter/SneakyCamCCPhoto.m ControlCenter/SneakyCamCCCommon.m SCPaths.m
SneakyCamCCPhoto_CFLAGS = -fobjc-arc -DSC_CC_VC_CLASS=SneakyCamCCPhotoViewController
SneakyCamCCPhoto_FRAMEWORKS = Foundation UIKit
SneakyCamCCPhoto_PRIVATE_FRAMEWORKS = ControlCenterUIKit
SneakyCamCCPhoto_INSTALL_PATH = /Library/ControlCenter/Bundles
SneakyCamCCPhoto_RESOURCE_DIRS = ControlCenter/resourcesPhoto

# 录像 CC 开关模块
SneakyCamCCVideo_FILES = ControlCenter/SneakyCamCCVideo.m ControlCenter/SneakyCamCCCommon.m SCPaths.m
SneakyCamCCVideo_CFLAGS = -fobjc-arc -DSC_CC_VC_CLASS=SneakyCamCCVideoViewController
SneakyCamCCVideo_FRAMEWORKS = Foundation UIKit
SneakyCamCCVideo_PRIVATE_FRAMEWORKS = ControlCenterUIKit
SneakyCamCCVideo_INSTALL_PATH = /Library/ControlCenter/Bundles
SneakyCamCCVideo_RESOURCE_DIRS = ControlCenter/resourcesVideo

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

before-package::
	core=$$(find $(THEOS_STAGING_DIR) -name 'SneakyCamCore.dylib' -type f | head -1); if [ -n "$$core" ]; then mv "$$core" "$${core%/*}/SneakyCam.dylib"; fi
	find $(THEOS_STAGING_DIR) -name 'SneakyCamCore.plist' -type f -delete
	find $(THEOS_STAGING_DIR) \( -name '*.dylib' -o -path '*/SneakyCam.bundle/SneakyCam' -o -path '*/SneakyCamCCToggle.bundle/SneakyCamCCToggle' -o -path '*/SneakyCamCCPhoto.bundle/SneakyCamCCPhoto' -o -path '*/SneakyCamCCVideo.bundle/SneakyCamCCVideo' \) -type f | while read f; do ldid -S "$$f" 2>/dev/null || true; done

after-install::
	install.exec "killall -9 SpringBoard mediaserverd 2>/dev/null || true"
