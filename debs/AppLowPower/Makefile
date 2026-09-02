export THEOS ?= /var/mobile/theos
export PATH := $(THEOS)/bin:$(PATH)
FINALPACKAGE = 1
export TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk
export ARCHS = arm64 arm64e

# make                        → rootless (默认)
# make SCHEME=roothide        → roothide
# THEOS_PACKAGE_SCHEME=roothide make  → CI 环境变量方式
ifeq ($(SCHEME),roothide)
export THEOS_PACKAGE_SCHEME := roothide
else ifeq ($(THEOS_PACKAGE_SCHEME),)
export THEOS_PACKAGE_SCHEME := rootless
endif

ROOTHIDE_LDFLAGS = -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide

TWEAK_NAME = AppLowPower
AppLowPower_FILES = Tweak.xm
AppLowPower_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE -fvisibility=hidden -DAPPLOWPOWER_STRIP_LOGS=1
AppLowPower_LDFLAGS += -Wl,-x -Wl,-dead_strip
AppLowPower_FRAMEWORKS = Foundation UIKit CoreFoundation
AppLowPower_LIBRARIES = substrate
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
AppLowPower_LDFLAGS += $(ROOTHIDE_LDFLAGS)
endif
include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = AppLowPowerSettings
AppLowPowerSettings_FILES = Settings/ALPRootListController.m
AppLowPowerSettings_INSTALL_PATH = /Library/PreferenceBundles
AppLowPowerSettings_CFLAGS = -fobjc-arc -Iinclude
AppLowPowerSettings_CODESIGN_FLAGS = -SSettings/Settings.entitlements
AppLowPowerSettings_FRAMEWORKS = UIKit Foundation
AppLowPowerSettings_PRIVATE_FRAMEWORKS = Preferences
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
AppLowPowerSettings_LDFLAGS += $(ROOTHIDE_LDFLAGS) -Wl,-undefined,dynamic_lookup
endif
include $(THEOS_MAKE_PATH)/bundle.mk

# 维护脚本按打包方案生成，避免连续双架构构建沿用上一次已替换的路径。
before-all::
	$(ECHO_NOTHING)if [ "$(THEOS_PACKAGE_SCHEME)" = "rootless" ]; then sed 's|@JBROOT@|/var/jb|g' "$(THEOS_PROJECT_DIR)/scripts/postinst.in" > "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst"; sed 's|@JBROOT@|/var/jb|g' "$(THEOS_PROJECT_DIR)/scripts/prerm.in" > "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"; else sed 's|@JBROOT@||g' "$(THEOS_PROJECT_DIR)/scripts/postinst.in" > "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst"; sed 's|@JBROOT@||g' "$(THEOS_PROJECT_DIR)/scripts/prerm.in" > "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"; fi$(ECHO_END)
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst" "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"$(ECHO_END)

before-package::
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst" "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"$(ECHO_END)

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/AppLowPowerSettings.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/AppLowPowerSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Root.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/AppLowPowerSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/icon.png Settings/icon@2x.png Settings/icon@3x.png "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/AppLowPowerSettings.bundle/"$(ECHO_END)
