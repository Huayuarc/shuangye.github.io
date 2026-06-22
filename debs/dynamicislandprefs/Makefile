THEOS ?= /var/jb/var/mobile/theos
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DynamicIslandPrefs
DynamicIslandPrefs_FILES = DIRootListController.m
DynamicIslandPrefs_CFLAGS = -fobjc-arc
DynamicIslandPrefs_FRAMEWORKS = UIKit
DynamicIslandPrefs_PRIVATE_FRAMEWORKS = Preferences
DynamicIslandPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
