DEBUG := 0
FINALPACKAGE := 1
export THEOS ?= /var/mobile/theos
export ARCHS := arm64 arm64e
TARGET := iphone:clang:16.5:14.0

export THEOS_PACKAGE_SCHEME := rootless
ifeq ($(SCHEME),roothide)
export THEOS_PACKAGE_SCHEME := roothide
endif

include $(THEOS)/makefiles/common.mk

# ---------- Tweak ----------
TWEAK_NAME = CPUthermal
CPUthermal_FILES = Tweak.xm
CPUthermal_CFLAGS = -fobjc-arc -I$(THEOS)/vendor/include
CPUthermal_FRAMEWORKS = Foundation IOKit

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CPUthermal_LDFLAGS += -lroothide -lsubstrate
else
CPUthermal_LDFLAGS += -lsubstrate
endif

include $(THEOS_MAKE_PATH)/tweak.mk

# ---------- PreferenceBundle ----------
BUNDLE_NAME = CPUthermalPrefs
CPUthermalPrefs_FILES = Settings/FRootListController.m
CPUthermalPrefs_INSTALL_PATH = /Library/PreferenceBundles
CPUthermalPrefs_CFLAGS = -fobjc-arc
CPUthermalPrefs_FRAMEWORKS = UIKit Foundation
CPUthermalPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk

# ---------- 打包阶段: 拷贝 PreferenceLoader 入口 + Info.plist ----------
after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences" "$(THEOS_STAGING_DIR)/DEBIAN"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/com.huayuarc.cputhermal.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalPrefs.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/icon@2x.png "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalPrefs.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/icon@3x.png "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/CPUthermalPrefs.bundle/"$(ECHO_END)

# ---------- roothide Architecture 修正 ----------
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
before-package::
	$(ECHO_NOTHING)sed -i 's/^Architecture:.*/Architecture: iphoneos-arm64e/' "$(THEOS_STAGING_DIR)/DEBIAN/control"$(ECHO_END)
endif

# ---------- 双包构建 ----------
PACKAGE_DIR = ./packages

build-all::
	$(MAKE) clean && $(MAKE) && $(MAKE) package
	$(MAKE) clean && $(MAKE) SCHEME=roothide && $(MAKE) package SCHEME=roothide
	@ls -la $(PACKAGE_DIR)/*.deb 2>/dev/null || echo "未找到 deb 文件"
