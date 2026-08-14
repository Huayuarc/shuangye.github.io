ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
TARGET := iphone:clang:16.5:14.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
TARGET := iphone:clang:16.5:14.0
else
TARGET := iphone:clang:14.5:11.0
endif

INSTALL_TARGET_PROCESSES = SpringBoard Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CCSupport
CCSupport_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/Headers
CCSupport_FILES = $(wildcard *.xm *.m)
CCSupport_PRIVATE_FRAMEWORKS = MobileIcons Preferences

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
else
CCSupport_CFLAGS += -D XINA_SUPPORT=1
endif

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += HomeProvider
include $(THEOS_MAKE_PATH)/aggregate.mk
