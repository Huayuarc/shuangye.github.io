TARGET := iphone:clang:16.5:15.0
FINALPACKAGE = 1
include $(THEOS)/makefiles/common.mk
TOOL_NAME = sbjetsamguard
TWEAK_NAME = SBJetsamGuardAutoTrim
sbjetsamguard_FILES = main.m ScriptFeatures.m MemoryTrimEngine.m
sbjetsamguard_FRAMEWORKS = Foundation
sbjetsamguard_CFLAGS = -std=c11 -fobjc-arc -Wall -Wextra -Werror -fvisibility=hidden
sbjetsamguard_INSTALL_PATH = /usr/libexec
sbjetsamguard_LDFLAGS = -Wl,-x -Wl,-dead_strip
sbjetsamguard_CODESIGN_FLAGS = -Sentitlements.plist
SBJetsamGuardAutoTrim_FILES = AutoTrimMonitor.m
SBJetsamGuardAutoTrim_FRAMEWORKS = Foundation
SBJetsamGuardAutoTrim_CFLAGS = -fobjc-arc -Wall -Wextra -Werror -fvisibility=hidden
SBJetsamGuardAutoTrim_LDFLAGS = -Wl,-x -Wl,-dead_strip
SBJetsamGuardAutoTrim_ARCHS = arm64 arm64e
SBJetsamGuardAutoTrim_VALID_ARCHS = arm64 arm64e
include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
before-all::
	python3 prepare.py $(THEOS_PACKAGE_SCHEME)
before-stage::
	python3 prepare.py $(THEOS_PACKAGE_SCHEME)
