DEBUG=0
FINALPACKAGE=1
THEOS_PACKAGE_SCHEME = rootless

# 【彻底规避云端make兼容性bug，不要使用 export + ?=】
ifndef THEOS
THEOS := /var/mobile/theos
endif

TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = 120hz
120hz_FILES = Tweak.xm

include $(THEOS_MAKE_PATH)/tweak.mk