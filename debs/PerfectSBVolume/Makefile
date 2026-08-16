ARCHS ?= arm64
TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PerfectSBVolume
PerfectSBVolume_FILES = Tweak.xm
PerfectSBVolume_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
PerfectSBVolume_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
