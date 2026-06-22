THEOS ?= /var/jb/var/mobile/theos
export LC_ALL = C
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DynamicIslandTweak
DynamicIslandTweak_FILES = Tweak.x DIContentView.m DIWindow.m DIDisplayManager.m DILocalization.m
DynamicIslandTweak_CFLAGS = -fobjc-arc
DynamicIslandTweak_FRAMEWORKS = UIKit CoreGraphics QuartzCore
# 使用 ObjC runtime hook（method_setImplementation），不链接 CydiaSubstrate
# 避免 arm64e 上 dyld 解析 CydiaSubstrate 时卡死导致看门狗
LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS_MAKE_PATH)/tweak.mk


ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
before-package::
	$(ECHO_NOTHING)python3 -c "from pathlib import Path; p=Path('$(THEOS_STAGING_DIR)/DEBIAN/control'); s=p.read_text(); s=s.replace(', oldabi', '').replace('oldabi, ', '').replace('Depends: oldabi\n', ''); p.write_text(s)"$(ECHO_END)
endif
