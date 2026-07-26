ifndef THEOS
THEOS := /var/mobile/theos
endif

export PATH := $(THEOS)/bin:$(PATH)
export TARGET = iphone:clang:16.5:15.0

THEOS_PACKAGE_SCHEME ?= rootless
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

INSTALL_TARGET_PROCESSES = thermalmonitord

TWEAK_NAME = CPUthermal

CPUthermal_FILES = Tweak.x LowPowerHooks.x ThermalSensorHooks.x CPUthermalHelper.m
CPUthermal_CFLAGS = -fobjc-arc -Iinclude -IHeaders -Wno-deprecated-declarations
CPUthermal_FRAMEWORKS = Foundation UIKit CoreFoundation IOKit SystemConfiguration

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += CPUthermalPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
