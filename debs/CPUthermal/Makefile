export THEOS ?= /var/mobile/theos
export PATH := $(THEOS)/bin:$(PATH)
FINALPACKAGE = 1
export TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk
# 不配置 INSTALL_TARGET_PROCESSES；安装/升级由 postinst 单独重启 thermalmonitord。
export ARCHS = arm64 arm64e
# ========== 双方案构建 ==========
ifeq ($(SCHEME),roothide)
export THEOS_PACKAGE_SCHEME := roothide
else ifeq ($(THEOS_PACKAGE_SCHEME),)
export THEOS_PACKAGE_SCHEME := rootless
endif

ROOTHIDE_LDFLAGS = -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide

TWEAK_NAME = CPUthermal CPUthermalPrefHook CPUthermalFaceDownLock CPUthermalForeground

CPUthermal_FILES = Tweak.x
CPUthermal_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE -fvisibility=hidden
CPUthermal_FRAMEWORKS = Foundation UIKit CoreFoundation IOKit

CPUthermalPrefHook_FILES = Tweak_PrefHook.xm
CPUthermalPrefHook_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE -fvisibility=hidden
CPUthermalPrefHook_FRAMEWORKS = Foundation CoreFoundation UIKit
CPUthermalPrefHook_LIBRARIES = substrate

CPUthermalFaceDownLock_FILES = FaceDownLock.xm
CPUthermalFaceDownLock_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE -fvisibility=hidden
CPUthermalFaceDownLock_FRAMEWORKS = Foundation UIKit CoreFoundation
CPUthermalFaceDownLock_LIBRARIES = substrate

CPUthermalForeground_FILES = ForegroundMode.xm
CPUthermalForeground_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE -fvisibility=hidden
CPUthermalForeground_FRAMEWORKS = Foundation UIKit CoreFoundation
CPUthermalForeground_LIBRARIES = substrate

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermal_LDFLAGS += $(ROOTHIDE_LDFLAGS)
CPUthermalPrefHook_LDFLAGS += $(ROOTHIDE_LDFLAGS)
CPUthermalFaceDownLock_LDFLAGS += $(ROOTHIDE_LDFLAGS)
CPUthermalForeground_LDFLAGS += $(ROOTHIDE_LDFLAGS)
endif
include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = CPUthermalSettings CPUthermalCC

CPUthermalSettings_FILES = Settings/FRootListController.m Settings/CPUthermalMountListController.m Settings/CPUthermalAppListController.m
CPUthermalSettings_INSTALL_PATH = /Library/PreferenceBundles
CPUthermalSettings_CFLAGS = -fobjc-arc -Iinclude
CPUthermalSettings_CODESIGN_FLAGS = -SSettings/Settings.entitlements
CPUthermalSettings_FRAMEWORKS = UIKit Foundation IOKit CoreFoundation
CPUthermalSettings_PRIVATE_FRAMEWORKS = Preferences
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
CPUthermalSettings_CFLAGS += -DCPUTHERMAL_ROOTLESS_MOUNT=1
endif
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalSettings_LDFLAGS += $(ROOTHIDE_LDFLAGS)
endif

CPUthermalCC_FILES = ControlCenter/CPUthermalCCModule.m ControlCenter/CPUthermalCCModuleViewController.m
CPUthermalCC_CFLAGS = -fobjc-arc -Iinclude
CPUthermalCC_FRAMEWORKS = Foundation UIKit ControlCenterUIKit
CPUthermalCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
CPUthermalCC_INSTALL_PATH = /Library/ControlCenter/Bundles/
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalCC_LDFLAGS += $(ROOTHIDE_LDFLAGS)
endif

include $(THEOS_MAKE_PATH)/bundle.mk

TOOL_NAME = CPUthermalTool CPUthermalMountTool CPUthermalMountClient CPUthermalChargeTool
CPUthermalTool_FILES = Tools/CPUthermalTool.m
CPUthermalTool_CFLAGS = -fobjc-arc -Iinclude
CPUthermalTool_CODESIGN_FLAGS = -STools/CPUthermalTool.entitlements
CPUthermalTool_INSTALL_PATH = /usr/local/bin
CPUthermalTool_FRAMEWORKS = Foundation SystemConfiguration

CPUthermalMountTool_FILES = Tools/CPUthermalMountTool.m
CPUthermalMountTool_CFLAGS = -fobjc-arc -fblocks -Iinclude
CPUthermalMountTool_CODESIGN_FLAGS = -STools/CPUthermalMountTool.entitlements
CPUthermalMountTool_INSTALL_PATH = /usr/local/bin
CPUthermalMountTool_FRAMEWORKS = Foundation CoreFoundation

CPUthermalMountClient_FILES = Tools/CPUthermalMountClient.m
CPUthermalMountClient_CFLAGS = -fobjc-arc -Iinclude
CPUthermalMountClient_CODESIGN_FLAGS = -STools/CPUthermalMountClient.entitlements
CPUthermalMountClient_INSTALL_PATH = /usr/local/bin
CPUthermalMountClient_FRAMEWORKS = Foundation

CPUthermalChargeTool_FILES = Tools/CPUthermalChargeTool.m
CPUthermalChargeTool_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations
CPUthermalChargeTool_CODESIGN_FLAGS = -STools/CPUthermalChargeTool.entitlements
CPUthermalChargeTool_INSTALL_PATH = /usr/local/bin
CPUthermalChargeTool_FRAMEWORKS = Foundation IOKit

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
CPUthermalMountTool_CFLAGS += -DCPUTHERMAL_ROOTLESS_MOUNT=1
endif
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalTool_LDFLAGS += $(ROOTHIDE_LDFLAGS)
CPUthermalMountTool_LDFLAGS += $(ROOTHIDE_LDFLAGS)
CPUthermalMountClient_LDFLAGS += $(ROOTHIDE_LDFLAGS)
CPUthermalChargeTool_LDFLAGS += $(ROOTHIDE_LDFLAGS)
endif
include $(THEOS_MAKE_PATH)/tool.mk

before-all::
	$(ECHO_NOTHING)if [ "$(THEOS_PACKAGE_SCHEME)" = "rootless" ]; then sed 's|@JBROOT@|/var/jb|g' "$(THEOS_PROJECT_DIR)/scripts/postinst.in" > "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst"; sed 's|@JBROOT@|/var/jb|g' "$(THEOS_PROJECT_DIR)/scripts/prerm.in" > "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"; else sed 's|@JBROOT@||g' "$(THEOS_PROJECT_DIR)/scripts/postinst.in" > "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst"; sed 's|@JBROOT@||g' "$(THEOS_PROJECT_DIR)/scripts/prerm.in" > "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"; fi$(ECHO_END)
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst" "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"$(ECHO_END)

before-package::
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst" "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"$(ECHO_END)

after-stage::
	$(ECHO_NOTHING)python3 -c 'import plistlib; p="$(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.huayuarc.cputhermal.mount.plist"; d=plistlib.load(open(p,"rb")); d["ProgramArguments"][0]="/var/jb/usr/local/bin/CPUthermalMountTool" if "$(THEOS_PACKAGE_SCHEME)"=="rootless" else "/usr/local/bin/CPUthermalMountTool"; plistlib.dump(d,open(p,"wb"),fmt=plistlib.FMT_XML,sort_keys=False); p="$(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.huayuarc.cputhermal.charge.plist"; d=plistlib.load(open(p,"rb")); d["ProgramArguments"][0]="/var/jb/usr/local/bin/CPUthermalChargeTool" if "$(THEOS_PACKAGE_SCHEME)"=="rootless" else "/usr/local/bin/CPUthermalChargeTool"; plistlib.dump(d,open(p,"wb"),fmt=plistlib.FMT_XML,sort_keys=False)'$(ECHO_END)

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences" "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/CPUthermalCC.bundle" "$(THEOS_STAGING_DIR)/usr/local/share/CPUthermal"$(ECHO_END)
	$(ECHO_NOTHING)cp PackagingAssets/D64AP-Info.plist "$(THEOS_STAGING_DIR)/usr/local/share/CPUthermal/D64AP-Info.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/CPUthermalSettings.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Root.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/icon.png Settings/icon@2x.png Settings/icon@3x.png "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp ControlCenter/resources/Info.plist "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/CPUthermalCC.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp ControlCenter/resources/SettingsIcon.png "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/CPUthermalCC.bundle/"$(ECHO_END)
