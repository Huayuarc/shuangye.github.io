FINALPACKAGE = 1

THEOS_PACKAGE_SCHEME = rootless

export TARGET = iphone:clang:16.5:15.0
export ADDITIONAL_CFLAGS = -DTHEOS_LEAN_AND_MEAN

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HalFiPadSB HalFiPadUI

HalFiPadSB_FILES = TweakSB.xm
HalFiPadUI_FILES = TweakUI.xm
HalFiPadUI_LIBRARIES = MobileGestalt

ARCHS = arm64 arm64e

HalFiPadSB_OBJCFLAGS = -fno-objc-arc
HalFiPadUI_OBJCFLAGS = -fno-objc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += HalFiPadPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "sbreload"
