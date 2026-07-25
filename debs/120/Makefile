DEBUG=0
FINALPACKAGE=1
export THEOS ?= /var/mobile/theos
THEOS = /var/mobile/theos

TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
export ARCHS

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = 120hz
120hz_FILES = Tweak.xm

include $(THEOS_MAKE_PATH)/tweak.mk
