# 仅本地iOS环境未定义THEOS变量时，才赋值手机路径，云端自动沿用系统环境变量
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

CPUthermal_FILES = Tweak.xm CPUthermalHelper.m
CPUthermal_CFLAGS = -fobjc-arc -IHeaders
CPUthermal_PRIVATE_FRAMEWORKS = IOKit

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += CPUthermalPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk