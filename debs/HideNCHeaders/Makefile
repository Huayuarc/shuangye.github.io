TARGET = iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HideNCHeaders
HideNCHeaders_FILES = HideNCHeaders.m
HideNCHeaders_CFLAGS = -fobjc-arc -Oz -fvisibility=hidden -Wall -Wextra
HideNCHeaders_LDFLAGS = -Wl,-x -Wl,-dead_strip
HideNCHeaders_FRAMEWORKS = UIKit Foundation
HideNCHeaders_PRIVATE_FRAMEWORKS = UserNotificationsUIKit

include $(THEOS_MAKE_PATH)/tweak.mk
