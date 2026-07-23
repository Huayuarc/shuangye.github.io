export THEOS ?= /var/mobile/theos
export PATH := $(THEOS)/bin:$(PATH)
export TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= rootless
include $(THEOS)/makefiles/common.mk
INSTALL_TARGET_PROCESSES = thermalmonitord

export ARCHS = arm64 arm64e

TWEAK_NAME = CPUthermal

CPUthermal_FILES = Tweak.xm CPUthermalHelper.m
CPUthermal_CFLAGS = -fobjc-arc -IHeaders
CPUthermal_PRIVATE_FRAMEWORKS = IOKit

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += CPUthermalPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
