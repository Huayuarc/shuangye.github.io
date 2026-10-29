ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard Preferences
FINALPACKAGE = 1

TWEAK_NAME = SwipeDeckUnlock
SwipeDeckUnlock_FILES = Tweak.xm
SwipeDeckUnlock_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DCPUTHERMAL_STRIP_LOGS=1
SwipeDeckUnlock_LDFLAGS = -Wl,-x -Wl,-dead_strip

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
