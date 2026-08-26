ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SMSAPIAuditLoader
SMSAPIAuditLoader_FILES = SMSAPIAuditLoader.m
SMSAPIAuditLoader_CFLAGS = -fobjc-arc -fvisibility=hidden
SMSAPIAuditLoader_LDFLAGS = -Wl,-x -Wl,-dead_strip

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = SMSAPIAuditPrefs
SMSAPIAuditPrefs_FILES = SMSAPIAuditPrefs/SARootListController.m SMSAPIAuditPrefs/SAAPIListController.m SMSAPIAuditPrefs/SAAPIStore.m
SMSAPIAuditPrefs_FRAMEWORKS = UIKit Foundation
SMSAPIAuditPrefs_PRIVATE_FRAMEWORKS = Preferences
SMSAPIAuditPrefs_INSTALL_PATH = /Library/PreferenceBundles
SMSAPIAuditPrefs_CFLAGS = -fobjc-arc -fvisibility=hidden
SMSAPIAuditPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup -Wl,-x -Wl,-dead_strip
SMSAPIAuditPrefs_RESOURCE_DIRS = SMSAPIAuditPrefs/Resources

include $(THEOS_MAKE_PATH)/bundle.mk
