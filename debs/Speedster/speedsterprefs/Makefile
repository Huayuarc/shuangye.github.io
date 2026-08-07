ARCHS = arm64 arm64e
export ARCHS

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SpeedsterPrefs

SpeedsterPrefs_FILES = sdrRootListController.m SdrSwitchCell.m SdrEQSliderCell.m
SpeedsterPrefs_FRAMEWORKS = UIKit AVFAudio
SpeedsterPrefs_PRIVATE_FRAMEWORKS = Preferences
SpeedsterPrefs_INSTALL_PATH = /Library/PreferenceBundles
SpeedsterPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
