export THEOS ?= /var/mobile/theos
export PATH := $(THEOS)/bin:$(PATH)
FINALPACKAGE = 1
export TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk
# 不配置 INSTALL_TARGET_PROCESSES；安装/升级由 postinst 单独重启 thermalmonitord。
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

ROOTHIDE_LDFLAGS = -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide

TWEAK_NAME = CPUthermal CPUthermalPrefHook

CPUthermal_FILES = Tweak.x CPUThermalRecovered.mm
CPUthermal_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE -fvisibility=hidden -DCPUTHERMAL_STRIP_LOGS=1
CPUthermal_LDFLAGS += -Wl,-x -Wl,-dead_strip
CPUthermal_FRAMEWORKS = Foundation UIKit CoreFoundation IOKit

CPUthermalPrefHook_FILES = Tweak_PrefHook.xm
CPUthermalPrefHook_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE -fvisibility=hidden -DCPUTHERMAL_STRIP_LOGS=1
CPUthermalPrefHook_LDFLAGS += -Wl,-x -Wl,-dead_strip
CPUthermalPrefHook_FRAMEWORKS = Foundation CoreFoundation UIKit
CPUthermalPrefHook_LIBRARIES = substrate

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermal_LDFLAGS += $(ROOTHIDE_LDFLAGS)
CPUthermalPrefHook_LDFLAGS += $(ROOTHIDE_LDFLAGS)
endif
include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = CPUthermalSettings CPUthermalCC

# PreferenceBundle: 设置面板
CPUthermalSettings_FILES = Settings/FRootListController.m
CPUthermalSettings_INSTALL_PATH = /Library/PreferenceBundles
CPUthermalSettings_CFLAGS = -fobjc-arc -Iinclude
CPUthermalSettings_CODESIGN_FLAGS = -SSettings/Settings.entitlements
CPUthermalSettings_FRAMEWORKS = UIKit Foundation
CPUthermalSettings_PRIVATE_FRAMEWORKS = Preferences
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalSettings_LDFLAGS += $(ROOTHIDE_LDFLAGS)
endif

# ControlCenter Bundle: 控制中心模块
CPUthermalCC_FILES = ControlCenter/CPUthermalCCModule.m ControlCenter/CPUthermalCCModuleViewController.m
CPUthermalCC_CFLAGS = -fobjc-arc -Iinclude
CPUthermalCC_FRAMEWORKS = Foundation UIKit ControlCenterUIKit
CPUthermalCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
CPUthermalCC_INSTALL_PATH = /Library/ControlCenter/Bundles/
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalCC_LDFLAGS += $(ROOTHIDE_LDFLAGS)
endif

include $(THEOS_MAKE_PATH)/bundle.mk

# 用户显式操作工具（模式切换不终止 thermalmonitord）
TOOL_NAME = CPUthermalTool
CPUthermalTool_FILES = Tools/CPUthermalTool.m
CPUthermalTool_CFLAGS = -fobjc-arc -Iinclude
CPUthermalTool_CODESIGN_FLAGS = -STools/CPUthermalTool.entitlements
CPUthermalTool_INSTALL_PATH = /usr/local/bin
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermalTool_LDFLAGS += $(ROOTHIDE_LDFLAGS)
endif
include $(THEOS_MAKE_PATH)/tool.mk

# 确保安装脚本进入 DEB 时具有可执行权限（共享文件系统可能丢失 mode bit）。
before-all::
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst"$(ECHO_END)

before-package::
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst"$(ECHO_END)

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences" "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/CPUthermalCC.bundle"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/CPUthermalSettings.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Root.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/icon.png Settings/icon@2x.png Settings/icon@3x.png "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp ControlCenter/resources/Info.plist "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/CPUthermalCC.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp ControlCenter/resources/SettingsIcon.png "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/CPUthermalCC.bundle/"$(ECHO_END)
