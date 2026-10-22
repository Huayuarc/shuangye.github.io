TARGET := iphone:clang:16.5:15.0
override ARCHS = arm64
override THEOS_PACKAGE_SCHEME = rootless
FINALPACKAGE = 1
DEBUG = 0
# This backend is Dopamine rootless only. Never relabel it as RootHide.
include $(THEOS)/makefiles/common.mk
TOOL_NAME = vnodebypass
vnodebypass_FILES = core/Controller.m core/kernel.m core/fishhook.c
vnodebypass_CFLAGS = -fobjc-arc -fblocks -Os -fvisibility=hidden
vnodebypass_LDFLAGS = -Wl,-x -Wl,-dead_strip
vnodebypass_CODESIGN_FLAGS = -Shelper-entitlements.plist
vnodebypass_FRAMEWORKS = Foundation CoreFoundation IOKit
vnodebypass_INSTALL_PATH = /usr/bin
include $(THEOS_MAKE_PATH)/tool.mk
SUBPROJECTS += ui
include $(THEOS_MAKE_PATH)/aggregate.mk
before-package::
	install -m 0755 scripts/preinst "$(THEOS_STAGING_DIR)/DEBIAN/preinst"
	install -m 0755 scripts/postinst "$(THEOS_STAGING_DIR)/DEBIAN/postinst"
	install -m 0755 scripts/prerm "$(THEOS_STAGING_DIR)/DEBIAN/prerm"
	chmod 0755 "$(THEOS_STAGING_DIR)/usr/bin/vnodebypass"
