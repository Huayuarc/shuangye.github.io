ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AkaraFix
AkaraFix_FILES = Tweak.xm Localization.xm
AkaraFix_CFLAGS = -fobjc-arc -Wall -Wextra
AkaraFix_FRAMEWORKS = UIKit Foundation
AkaraFix_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
