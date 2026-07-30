ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME ?= rootless
export ARCHS
TARGET := iphone:clang:16.5:14.0

ifndef THEOS
THEOS := /var/mobile/theos
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Speedster

Speedster_FILES = Speedster.x
Speedster_FRAMEWORKS = UIKit Foundation QuartzCore Metal
Speedster_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += speedsterprefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "sbreload"
