TARGET := iphone:clang:16.5:15.0
FINALPACKAGE = 1
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SBJetsamGuardPrefs
SBJetsamGuardPrefs_FILES = SJGRootListController.m
SBJetsamGuardPrefs_FRAMEWORKS = UIKit Foundation
# Preferences is supplied by Settings/PreferenceLoader at runtime. Some SDKs have
# headers but no Preferences.tbd; deliberately do not use _PRIVATE_FRAMEWORKS.
SBJetsamGuardPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
SBJetsamGuardPrefs_CFLAGS = -fobjc-arc -Wall -Wextra
SBJetsamGuardPrefs_INSTALL_PATH = /Library/PreferenceBundles
SBJetsamGuardPrefs_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/bundle.mk
