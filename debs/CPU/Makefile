export THEOS = /rootfs/var/mobile/theos
export THEOS_PACKAGE_SCHEME = rootless
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = thermalmonitord

include $(THEOS)/makefiles/common.mk

# ============================================================
# CPUthermal 主插件 (thermalmonitord)
# ============================================================
TWEAK_NAME = CPUthermal
CPUthermal_FILES = Tweak.x PowercuffManager.m
CPUthermal_CFLAGS = -fobjc-arc -Iinclude
CPUthermal_FRAMEWORKS = Foundation UIKit IOKit SystemConfiguration
CPUthermal_PRIVATE_FRAMEWORKS = AppSupport

include $(THEOS_MAKE_PATH)/tweak.mk

# ============================================================
# CPUthermal 设置钩子 (Preferences.app)
# ============================================================
TWEAK_NAME = CPUthermalPrefHook
CPUthermalPrefHook_FILES = Tweak_PrefHook.xm
CPUthermalPrefHook_CFLAGS = -fobjc-arc -Iinclude -stdlib=libc++
CPUthermalPrefHook_LDFLAGS = -lc++
CPUthermalPrefHook_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

# ============================================================
# CPUthermal CC 模块 (控制中心)
# ============================================================
BUNDLE_NAME = CPUthermalCC
CPUthermalCC_FILES = \
	ControlCenter/CPUthermalCCModule.m \
	ControlCenter/CPUthermalCCModuleViewController.m
CPUthermalCC_CFLAGS = -fobjc-arc -Iinclude
CPUthermalCC_FRAMEWORKS = UIKit ControlCenterUIKit
CPUthermalCC_INSTALL_PATH = /Library/ControlCenter/Bundles/
CPUthermalCC_RESOURCE_DIRS = ControlCenter/resources

include $(THEOS_MAKE_PATH)/bundle.mk

# ============================================================
# CPUthermal 设置面板 (设置 App)
# ============================================================
BUNDLE_NAME = CPUthermalSettings
CPUthermalSettings_FILES = Settings/FRootListController.m
CPUthermalSettings_CFLAGS = -fobjc-arc -Iinclude
CPUthermalSettings_FRAMEWORKS = UIKit Foundation
CPUthermalSettings_PRIVATE_FRAMEWORKS = Preferences
CPUthermalSettings_INSTALL_PATH = /Library/PreferenceBundles/
CPUthermalSettings_RESOURCE_DIRS = Settings/resources

include $(THEOS_MAKE_PATH)/bundle.mk

# ============================================================
# CPUthermal 命令行工具
# ============================================================
TOOL_NAME = CPUthermalTool
CPUthermalTool_FILES = Tools/CPUthermalTool.m
CPUthermalTool_CFLAGS = -fobjc-arc -Iinclude
CPUthermalTool_FRAMEWORKS = Foundation SystemConfiguration
CPUthermalTool_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tool.mk
