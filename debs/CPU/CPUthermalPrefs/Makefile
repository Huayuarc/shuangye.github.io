TARGET := iphone:clang:latest:12.2

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CPUthermalPrefs

CPUthermalPrefs_FILES = Sources/CPUthermalPrefs.m
CPUthermalPrefs_INSTALL_PATH = /Library/PreferenceBundles
CPUthermalPrefs_CFLAGS = -fobjc-arc -I../Headers

include $(THEOS_MAKE_PATH)/bundle.mk
