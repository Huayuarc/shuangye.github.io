include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = VivoStylePrefs

VivoStylePrefs_FILES = VVSPrefsController.m
VivoStylePrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
VivoStylePrefs_FRAMEWORKS = UIKit Photos PhotosUI
# Preferences (PSListController/PSSpecifier) is a private framework with no SDK
# stub; its symbols are provided by Settings at load time, so resolve lazily.
VivoStylePrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
VivoStylePrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS)/makefiles/bundle.mk
