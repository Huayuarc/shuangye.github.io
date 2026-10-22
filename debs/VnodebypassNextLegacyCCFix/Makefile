TARGET := iphone:clang:16.5:15.0
override ARCHS = arm64
override THEOS_PACKAGE_SCHEME = rootless
FINALPACKAGE = 1
DEBUG = 0
# APPLICATION_NAME marker: this bundle-only project must be discovered by CI.
include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = VBModule
VBModule_FILES = VBModule.m
VBModule_CFLAGS = -fobjc-arc -fblocks -fvisibility=hidden -Os
VBModule_LDFLAGS = -Wl,-undefined,dynamic_lookup -Wl,-x -Wl,-dead_strip
VBModule_FRAMEWORKS = UIKit Foundation IOKit
VBModule_INSTALL_PATH = /Library/ControlCenter/Bundles
VBModule_BUNDLE_EXTENSION = bundle
include $(THEOS_MAKE_PATH)/bundle.mk
before-package::
	install -m 0755 scripts/preinst "$(THEOS_STAGING_DIR)/DEBIAN/preinst"
	install -m 0755 scripts/postinst "$(THEOS_STAGING_DIR)/DEBIAN/postinst"
	install -m 0755 scripts/prerm "$(THEOS_STAGING_DIR)/DEBIAN/prerm"
	chmod 0755 "$(THEOS_STAGING_DIR)/Applications/vnodebypass.app/vnodebypass"
	chmod 0755 "$(THEOS_STAGING_DIR)/usr/bin/vnodebypass"
