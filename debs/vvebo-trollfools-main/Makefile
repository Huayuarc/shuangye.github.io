ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:14.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = VVeboFix
VVeboFix_FILES = Tweak.x
VVeboFix_CFLAGS = -fobjc-arc
include $(THEOS)/makefiles/tweak.mk