export THEOS ?= /var/mobile/theos
export PATH := $(THEOS)/bin:$(PATH)
export TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= rootless
include $(THEOS)/makefiles/common.mk
INSTALL_TARGET_PROCESSES = thermalmonitord
# 注意: postinst 也在 configure 阶段 killall thermalmonitord。
# INSTALL_TARGET_PROCESSES 作为 make install 时的兜底（包管理器安装靠 postinst）
export ARCHS = arm64 arm64e

TWEAK_NAME = CPUthermal CPUthermalPrefHook

CPUthermal_FILES = Tweak.xm
CPUthermal_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE
CPUthermal_FRAMEWORKS = Foundation UIKit CoreFoundation IOKit
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermal_LDFLAGS += -lroothide
endif

# ThermalManager hook (Preferences 中的散热建议拦截)
CPUthermalPrefHook_FILES = Tweak_PrefHook.xm
CPUthermalPrefHook_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations
CPUthermalPrefHook_FRAMEWORKS = Foundation CoreFoundation
CPUthermalPrefHook_LDFLAGS = -lsubstrate -lc++
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalPrefHook_LDFLAGS += -lroothide
endif
include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = CPUthermalSettings CPUthermalCC CPUthermalFreqCC

# PreferenceBundle: 设置面板
CPUthermalSettings_FILES = Settings/FRootListController.m
CPUthermalSettings_INSTALL_PATH = /Library/PreferenceBundles
CPUthermalSettings_CFLAGS = -fobjc-arc -Iinclude
CPUthermalSettings_CODESIGN_FLAGS = -SSettings/Settings.entitlements
CPUthermalSettings_FRAMEWORKS = UIKit Foundation
CPUthermalSettings_PRIVATE_FRAMEWORKS = Preferences
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalSettings_LDFLAGS += -lroothide
endif

# ControlCenter Bundle: 控制中心模块
CPUthermalCC_FILES = CCModule/CPUthermalCCModule.m CCModule/CPUthermalCCModuleViewController.m
CPUthermalCC_CFLAGS = -fobjc-arc -Iinclude
CPUthermalCC_FRAMEWORKS = Foundation UIKit ControlCenterUIKit
CPUthermalCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
CPUthermalCC_INSTALL_PATH = /Library/ControlCenter/Bundles/
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalCC_LDFLAGS += -lroothide
endif

# ControlCenter Bundle: CPU 真实频率显示模块
CPUthermalFreqCC_FILES = CCModule/CPUthermalFreqCCModule.m CCModule/CPUthermalFreqCCModuleViewController.m
CPUthermalFreqCC_CFLAGS = -fobjc-arc -Iinclude
CPUthermalFreqCC_CODESIGN_FLAGS = -SCCModule/CPUthermalFreq.entitlements
CPUthermalFreqCC_FRAMEWORKS = Foundation UIKit CoreFoundation IOKit QuartzCore ControlCenterUIKit
CPUthermalFreqCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
CPUthermalFreqCC_LDFLAGS += -lIOReport
CPUthermalFreqCC_INSTALL_PATH = /Library/ControlCenter/Bundles/
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalFreqCC_LDFLAGS += -lroothide
endif

include $(THEOS_MAKE_PATH)/bundle.mk

# 用户空间重启工具
TOOL_NAME = CPUthermalTool
CPUthermalTool_FILES = Tools/CPUthermalTool.m
CPUthermalTool_CFLAGS = -fobjc-arc -Iinclude
CPUthermalTool_CODESIGN_FLAGS = -STools/CPUthermalTool.entitlements
CPUthermalTool_INSTALL_PATH = /usr/local/bin
include $(THEOS_MAKE_PATH)/tool.mk

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences" "$(THEOS_STAGING_DIR)/DEBIAN" "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/CPUthermalCC.bundle" "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/CPUthermalFreqCC.bundle"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/CPUthermalSettings.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Root.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/icon.png Settings/icon@2x.png Settings/icon@3x.png "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp CCModule/Info.plist "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/CPUthermalCC.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp CCModule/SettingsIcon.png "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/CPUthermalCC.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp CCModule/CPUthermalFreqInfo.plist "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/CPUthermalFreqCC.bundle/Info.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp CCModule/SettingsIcon.png "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/CPUthermalFreqCC.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp postinst "$(THEOS_STAGING_DIR)/DEBIAN/" && chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst"$(ECHO_END)
