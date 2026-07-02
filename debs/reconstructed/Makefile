# ============================================================================
# Makefile — Heaven 逆向还原项目编译配置
# [RE] 此 Makefile 为逆向还原参考，实际编译可能需要调整
# ============================================================================

# --- 项目配置 ---
THEOS_PACKAGE_SCHEME = rootless
export THEOS_PACKAGE_SCHEME

TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
export ARCHS

include $(THEOS)/makefiles/common.mk

# --- 主插件 (dylib) ---
TWEAK_NAME = Heaven

Heaven_FILES = Heaven.xm
Heaven_CFLAGS = -fobjc-arc -I.
Heaven_LIBRARIES = substrate
Heaven_FRAMEWORKS = UIKit Foundation Security CoreLocation AdSupport CoreTelephony SystemConfiguration

# [RE] 推测: 原插件可能还链接了以下框架
# Heaven_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk

# --- PreferenceBundle ---
BUNDLE_NAME = HeavenPrefs

HeavenPrefs_FILES = \
	HeavenRootListController.m

HeavenPrefs_CFLAGS = -fobjc-arc -I.
HeavenPrefs_FRAMEWORKS = UIKit Foundation
HeavenPrefs_PRIVATE_FRAMEWORKS = Preferences
HeavenPrefs_INSTALL_PATH = /Library/PreferenceBundles
HeavenPrefs_RESOURCE_FILES = Root.plist entry.plist icon.png icon@2x.png icon@3x.png HeavenLogo.png

include $(THEOS_MAKE_PATH)/bundle.mk

# --- 安装后操作 ---
after-install::
	install.exec "killall -9 SpringBoard" || true

# --- 清理 ---
clean::
	rm -rf $(THEOS_STAGING_DIR)
	rm -rf .theos
