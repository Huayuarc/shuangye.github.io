ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard Preferences
# TWEAK_NAME marker for repository CI discovery
include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = PictureModule1 PictureModule2 PictureModule3 PictureModule4 PictureModule5
$(foreach n,1 2 3 4 5,$(eval PictureModule$(n)_FILES = PMPaths.m PMOriginal.m PMSettings.m PictureModule$(n).m))
$(foreach n,1 2 3 4 5,$(eval PictureModule$(n)_FRAMEWORKS = UIKit Foundation PhotosUI Photos AVFoundation WebKit UniformTypeIdentifiers))
$(foreach n,1 2 3 4 5,$(eval PictureModule$(n)_PRIVATE_FRAMEWORKS = ControlCenterUIKit Preferences))
$(foreach n,1 2 3 4 5,$(eval PictureModule$(n)_CFLAGS = -fobjc-arc -Wno-deprecated-declarations))
$(foreach n,1 2 3 4 5,$(eval PictureModule$(n)_RESOURCE_DIRS = Resources$(n)))
$(foreach n,1 2 3 4 5,$(eval PictureModule$(n)_INSTALL_PATH = /Library/ControlCenter/Bundles))
include $(THEOS_MAKE_PATH)/bundle.mk
