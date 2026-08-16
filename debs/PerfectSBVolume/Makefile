ARCHS ?= arm64
TARGET = iphone:clang:16.5:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PerfectSBVolume
PerfectSBVolume_FILES = Tweak.xm
PerfectSBVolume_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
PerfectSBVolume_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
