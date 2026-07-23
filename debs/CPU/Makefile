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

BUNDLE_NAME = CPUthermalPrefs
CPUthermalPrefs_FILES = CPUthermalPrefs/Sources/CPUthermalPrefs.m
CPUthermalPrefs_INSTALL_PATH = /Library/PreferenceBundles
CPUthermalPrefs_CFLAGS = -fobjc-arc -IHeaders
include $(THEOS_MAKE_PATH)/bundle.mk
