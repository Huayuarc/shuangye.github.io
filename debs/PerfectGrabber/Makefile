TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME ?= rootless
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ARCHS = arm64e
else
ARCHS = arm64
endif
INSTALL_TARGET_PROCESSES = SpringBoard Preferences
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PerfectGrabber
PerfectGrabber_FILES = Tweak.xm PerfectGrabberPreferences.m PGGrabberOverlayView.m PGGrabberHUDView.m PGSystemStatus.m
PerfectGrabber_CFLAGS = -fobjc-arc
PerfectGrabber_FRAMEWORKS = Foundation UIKit AudioToolbox IOKit

BUNDLE_NAME = PerfectGrabberSettings
PerfectGrabberSettings_FILES = prefs/PerfectGrabberSettingsController.m
PerfectGrabberSettings_INSTALL_PATH = /Library/PreferenceBundles
PerfectGrabberSettings_FRAMEWORKS = Foundation UIKit
PerfectGrabberSettings_CFLAGS = -fobjc-arc
PerfectGrabberSettings_LDFLAGS = -Wl,-undefined,dynamic_lookup
PerfectGrabberSettings_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
