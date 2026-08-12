ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard
# TWEAK_NAME marker used by repository CI project discovery.
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = PictureModule16_1 PictureModule16_2 PictureModule16_3 PictureModule16_4 PictureModule16_5

PictureModule16_1_FILES = PM16Base.m PictureModule16_1.m
PictureModule16_2_FILES = PM16Base.m PictureModule16_2.m
PictureModule16_3_FILES = PM16Base.m PictureModule16_3.m
PictureModule16_4_FILES = PM16Base.m PictureModule16_4.m
PictureModule16_5_FILES = PM16Base.m PictureModule16_5.m

$(foreach n,1 2 3 4 5,$(eval PictureModule16_$(n)_FRAMEWORKS = UIKit Foundation PhotosUI Photos AVFoundation UniformTypeIdentifiers))
$(foreach n,1 2 3 4 5,$(eval PictureModule16_$(n)_PRIVATE_FRAMEWORKS = ControlCenterUIKit))
$(foreach n,1 2 3 4 5,$(eval PictureModule16_$(n)_CFLAGS = -fobjc-arc -Wno-deprecated-declarations))
$(foreach n,1 2 3 4 5,$(eval PictureModule16_$(n)_RESOURCE_DIRS = Resources$(n)))
$(foreach n,1 2 3 4 5,$(eval PictureModule16_$(n)_INSTALL_PATH = /Library/ControlCenter/Bundles))

include $(THEOS_MAKE_PATH)/bundle.mk
