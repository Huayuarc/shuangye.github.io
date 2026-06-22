# Set default values (can be overridden by environment)
DEBUG = 0
FINALPACKAGE = 1
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard Preferences
THEOS_PACKAGE_SCHEME ?= rootless

# Include common settings
include $(THEOS)/makefiles/common.mk

# Tweak configuration
TWEAK_NAME = CC26
$(TWEAK_NAME)_FILES = Tweak.xm CC26Preferences/CC26LocalizableManager.m
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wno-error -fno-modules
$(TWEAK_NAME)_PRIVATE_FRAMEWORKS = ControlCenterUIKit MediaControls

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += CC26Preferences
include $(THEOS_MAKE_PATH)/aggregate.mk
