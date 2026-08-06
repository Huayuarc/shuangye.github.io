ARCHS = arm64 arm64e
export ARCHS
TARGET := iphone:clang:16.5:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

ifndef THEOS
THEOS := /var/mobile/theos
endif
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Speedster

Speedster_FILES = Speedster.x SpeedsterDock.xm
Speedster_FRAMEWORKS = UIKit Foundation QuartzCore Metal
Speedster_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new
Speedster_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += speedsterprefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
install.exec "sbreload"
