ifndef THEOS
THEOS := /var/mobile/theos
endif

# 和主项目保持一致TARGET，版本统一，解决符号找不到问题
TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CPUthermalPrefs

CPUthermalPrefs_FILES = Sources/CPUthermalPrefs.m Sources/CPUthermalHelper.m
CPUthermalPrefs_INSTALL_PATH = /Library/PreferenceBundles
CPUthermalPrefs_CFLAGS = -fobjc-arc -I../Headers -I../include
# 声明私有框架，解决PSListController链接错误
CPUthermalPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk