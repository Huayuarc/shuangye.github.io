export THEOS ?= /var/mobile/theos
export PATH := $(THEOS)/bin:$(PATH)
export TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk
INSTALL_TARGET_PROCESSES = SpringBoard thermalmonitord
# 注意: postinst 也在 configure 阶段 killall thermalmonitord。
# INSTALL_TARGET_PROCESSES 作为 make install 时的兜底（包管理器安装靠 postinst）
export ARCHS = arm64 arm64e
# ========== 双方案构建 ==========
# make                        → 构建 rootless (默认)
# make SCHEME=roothide        → 构建 roothide
# THEOS_PACKAGE_SCHEME=roothide make  → 构建 roothide (CI 环境变量方式)
# make build-all              → 同时构建 rootless + roothide

ifeq ($(SCHEME),roothide)
export THEOS_PACKAGE_SCHEME := roothide
else ifeq ($(THEOS_PACKAGE_SCHEME),)
# 未通过 SCHEME 或环境变量指定时，默认 rootless
export THEOS_PACKAGE_SCHEME := rootless
endif

TWEAK_NAME = CPUthermal CPUthermalPrefHook

CPUthermal_FILES = Tweak.x ThermalPatcher_supplement.x
CPUthermal_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE
CPUthermal_FRAMEWORKS = Foundation UIKit CoreFoundation IOKit SystemConfiguration
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermal_LDFLAGS += -lroothide
endif

BUNDLE_NAME = CPUthermalCC CPUthermalSettings

# CPUthermalCC: 控制中心模块
CPUthermalCC_FILES = \
	ControlCenter/CPUthermalCCModule.m \
	ControlCenter/CPUthermalCCModuleViewController.m
CPUthermalCC_CFLAGS = -fobjc-arc -Iinclude
CPUthermalCC_FRAMEWORKS = UIKit ControlCenterUIKit
CPUthermalCC_INSTALL_PATH = /Library/ControlCenter/Bundles/
CPUthermalCC_RESOURCE_DIRS = ControlCenter/resources

# ThermalManager hook (Preferences 中的散热建议拦截)
CPUthermalPrefHook_FILES = Tweak_PrefHook.x
CPUthermalPrefHook_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations
CPUthermalPrefHook_FRAMEWORKS = Foundation CoreFoundation
CPUthermalPrefHook_LDFLAGS = -lsubstrate -lc++
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalPrefHook_LDFLAGS += -lroothide
endif
include $(THEOS_MAKE_PATH)/tweak.mk

# CPUthermalSettings: 偏好设置面板

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

include $(THEOS_MAKE_PATH)/bundle.mk

# 用户空间重启工具
TOOL_NAME = CPUthermalTool
CPUthermalTool_FILES = Tools/CPUthermalTool.m
CPUthermalTool_CFLAGS = -fobjc-arc -Iinclude
CPUthermalTool_CODESIGN_FLAGS = -STools/CPUthermalTool.entitlements
CPUthermalTool_INSTALL_PATH = /usr/local/bin
CPUthermalTool_FRAMEWORKS = Foundation SystemConfiguration
include $(THEOS_MAKE_PATH)/tool.mk

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences" "$(THEOS_STAGING_DIR)/DEBIAN"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/CPUthermalSettings.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Root.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/icon.png Settings/icon@2x.png Settings/icon@3x.png "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp postinst "$(THEOS_STAGING_DIR)/DEBIAN/" && chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst"$(ECHO_END)
