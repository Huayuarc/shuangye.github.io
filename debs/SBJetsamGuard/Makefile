TARGET := iphone:clang:16.5:15.0
FINALPACKAGE = 1
include $(THEOS)/makefiles/common.mk
TOOL_NAME = sbjetsamguard
sbjetsamguard_FILES = main.m ScriptFeatures.m
sbjetsamguard_FRAMEWORKS = Foundation
sbjetsamguard_CFLAGS = -std=c11 -fobjc-arc -Wall -Wextra -Werror -fvisibility=hidden
sbjetsamguard_INSTALL_PATH = /usr/libexec
sbjetsamguard_LDFLAGS = -Wl,-x -Wl,-dead_strip
sbjetsamguard_CODESIGN_FLAGS = -Sentitlements.plist
include $(THEOS_MAKE_PATH)/tool.mk
SUBPROJECTS += Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
before-all::
	python3 prepare.py $(THEOS_PACKAGE_SCHEME)
before-stage::
	python3 prepare.py $(THEOS_PACKAGE_SCHEME)
