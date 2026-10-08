TARGET := iphone:clang:latest:13.0
ARCHS = arm64 arm64e
FINALPACKAGE = 1
INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk
TWEAK_NAME = SnapperAboutHide
SnapperAboutHide_FILES = Tweak.m
SnapperAboutHide_FRAMEWORKS = Foundation
SnapperAboutHide_CFLAGS = -fno-objc-arc -fvisibility=hidden
SnapperAboutHide_LDFLAGS = -Wl,-x -Wl,-dead_strip
include $(THEOS_MAKE_PATH)/tweak.mk
