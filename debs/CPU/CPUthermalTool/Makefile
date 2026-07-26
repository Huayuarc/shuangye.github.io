ifndef THEOS
THEOS := /var/mobile/theos
endif

export PATH := $(THEOS)/bin:$(PATH)
export TARGET = iphone:clang:16.5:15.0

THEOS_PACKAGE_SCHEME ?= rootless
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = CPUthermalTool

CPUthermalTool_FILES = main.m
CPUthermalTool_CFLAGS = -fobjc-arc -I../include
CPUthermalTool_FRAMEWORKS = Foundation IOKit
CPUthermalTool_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tool.mk
