export THEOS ?= /var/mobile/theos
export PATH := $(THEOS)/bin:$(PATH)
export TARGET = iphone:clang:16.5:15.0
export THEOS_PACKAGE_SCHEME ?= rootless
include $(THEOS)/makefiles/common.mk
INSTALL_TARGET_PROCESSES = thermalmonitord
# 注意: postinst 也在 configure 阶段 killall thermalmonitord。
# INSTALL_TARGET_PROCESSES 作为 make install 时的兜底（包管理器安装靠 postinst）
export ARCHS = arm64 arm64e
# ========== 双方案构建 ==========
# make                        → 构建 rootless (默认)
# make SCHEME=roothide        → 构建 roothide
# THEOS_PACKAGE_SCHEME=roothide make  → 构建 roothide (CI 环境变量方式)
# make build-all              → 同时构建 rootless + roothide
#
# 注意: roothide 分支的 Theos 在 common.mk 中会将 THEOS_PACKAGE_SCHEME
# 修改为 roothide 默认值，所以必须在 include 之后重新检查 SCHEME 变量

ifeq ($(SCHEME),roothide)
export THEOS_PACKAGE_SCHEME := roothide
else
# 未通过 SCHEME=roothide 明确指定时，统一为 rootless
override export THEOS_PACKAGE_SCHEME := rootless
endif

COMMON_SWIFT_FILES = Shared/CPUthermalShared.swift
COMMON_BRIDGE_FILES = Shared/CPUthermalSwiftBridge.m

TWEAK_NAME = CPUthermal CPUthermalPrefHook

CPUthermal_FILES = Tweak.swift
CPUthermal_SWIFT_BRIDGING_HEADER = Tweak-Bridging-Header.h
CPUthermal_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE
CPUthermal_FRAMEWORKS = Foundation CoreFoundation IOKit
CPUthermal_LDFLAGS = -lsubstrate
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermal_LDFLAGS += -lroothide
endif

# ThermalManager hook (Preferences 中的散热建议拦截)
CPUthermalPrefHook_FILES = TweakPrefHook.swift
CPUthermalPrefHook_SWIFT_BRIDGING_HEADER = TweakPrefHook-Bridging-Header.h
CPUthermalPrefHook_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations
CPUthermalPrefHook_FRAMEWORKS = Foundation CoreFoundation
CPUthermalPrefHook_LDFLAGS = -lsubstrate -lc++
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalPrefHook_LDFLAGS += -lroothide
endif
include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = CPUthermalSettings CPUthermalCC CPUthermalFreqCC

# PreferenceBundle: 设置面板 (Swift)
CPUthermalSettings_FILES = Settings/FRootListController.swift $(COMMON_SWIFT_FILES) $(COMMON_BRIDGE_FILES)
CPUthermalSettings_SWIFT_BRIDGING_HEADER = Settings/CPUthermalSettings-Bridging-Header.h
CPUthermalSettings_INSTALL_PATH = /Library/PreferenceBundles
CPUthermalSettings_CFLAGS = -fobjc-arc -Iinclude
CPUthermalSettings_CODESIGN_FLAGS = -SSettings/Settings.entitlements
CPUthermalSettings_FRAMEWORKS = UIKit Foundation
CPUthermalSettings_PRIVATE_FRAMEWORKS = Preferences
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalSettings_LDFLAGS += -lroothide
endif

# ControlCenter Bundle: 控制中心模块 (Swift)
CPUthermalCC_FILES = CCModule/CPUthermalCCModule.swift CCModule/CPUthermalCCModuleViewController.swift $(COMMON_SWIFT_FILES) $(COMMON_BRIDGE_FILES)
CPUthermalCC_SWIFT_BRIDGING_HEADER = CCModule/CPUthermalCC-Bridging-Header.h
CPUthermalCC_CFLAGS = -fobjc-arc -Iinclude -ICCModule
CPUthermalCC_FRAMEWORKS = Foundation UIKit ControlCenterUIKit
CPUthermalCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
CPUthermalCC_INSTALL_PATH = /Library/ControlCenter/Bundles/
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalCC_LDFLAGS += -lroothide
endif

# ControlCenter Bundle: CPU 真实频率显示模块 (Swift)
CPUthermalFreqCC_FILES = CCModule/CPUthermalFreqCCModule.swift CCModule/CPUthermalFreqCCModuleViewController.swift $(COMMON_SWIFT_FILES) $(COMMON_BRIDGE_FILES)
CPUthermalFreqCC_SWIFT_BRIDGING_HEADER = CCModule/CPUthermalFreqCC-Bridging-Header.h
CPUthermalFreqCC_CFLAGS = -fobjc-arc -Iinclude -ICCModule
CPUthermalFreqCC_CODESIGN_FLAGS = -SCCModule/CPUthermalFreq.entitlements
CPUthermalFreqCC_FRAMEWORKS = Foundation UIKit CoreFoundation IOKit QuartzCore ControlCenterUIKit
CPUthermalFreqCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
CPUthermalFreqCC_INSTALL_PATH = /Library/ControlCenter/Bundles/
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalFreqCC_LDFLAGS += -lroothide
endif

include $(THEOS_MAKE_PATH)/bundle.mk

# 用户空间重启工具 (Swift)
TOOL_NAME = CPUthermalTool
CPUthermalTool_FILES = Tools/main.swift $(COMMON_SWIFT_FILES) $(COMMON_BRIDGE_FILES)
CPUthermalTool_SWIFT_BRIDGING_HEADER = Tools/CPUthermalTool-Bridging-Header.h
CPUthermalTool_CFLAGS = -fobjc-arc -Iinclude
CPUthermalTool_CODESIGN_FLAGS = -STools/CPUthermalTool.entitlements
CPUthermalTool_INSTALL_PATH = /usr/local/bin
include $(THEOS_MAKE_PATH)/tool.mk

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/PreferenceLoader/Preferences" "$(THEOS_STAGING_DIR)/DEBIAN" "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/ControlCenter/Bundles/CPUthermalCC.bundle" "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/ControlCenter/Bundles/CPUthermalFreqCC.bundle"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/entry.plist "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/PreferenceLoader/Preferences/CPUthermalSettings.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Info.plist "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Root.plist "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/icon.png Settings/icon@2x.png Settings/icon@3x.png "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp CCModule/Info.plist "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/ControlCenter/Bundles/CPUthermalCC.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp CCModule/SettingsIcon.png "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/ControlCenter/Bundles/CPUthermalCC.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp CCModule/CPUthermalFreqInfo.plist "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/ControlCenter/Bundles/CPUthermalFreqCC.bundle/Info.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp CCModule/SettingsIcon.png "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/ControlCenter/Bundles/CPUthermalFreqCC.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp postinst "$(THEOS_STAGING_DIR)/DEBIAN/" && chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst"$(ECHO_END)

# ========== 构建辅助 ==========
# 一键构建 rootless + roothide 两种方案
# 用法: make build-all
build-all:
	$(MAKE) SCHEME=rootless package
	$(MAKE) SCHEME=roothide package

.PHONY: build-all
