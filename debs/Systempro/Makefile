DEBUG := 0
FINALPACKAGE := 1
_THEOS_TOP_INVOCATION_DONE :=
export _THEOS_TOP_INVOCATION_DONE

# Theos 路徑（CI 會覆蓋此值）
ifeq ($(THEOS),)
THEOS := /var/mobile/theos
endif
export THEOS

export ARCHS := arm64 arm64e
TARGET := iphone:clang:16.5:14.0

# on-device 編譯需指定 bash
ifneq ($(wildcard /var/jb/bin/bash),)
SHELL := /var/jb/bin/bash
endif

# ========== 方案選擇 ==========
# make                     → 同時輸出 rootless + roothide (on-device 預設)
# make SCHEME=rootless     → 只編 rootless
# make SCHEME=roothide     → 只編 roothide
# THEOS_PACKAGE_SCHEME=xxx make  → CI 用，只編指定方案
ifeq ($(SCHEME),)
  ifeq ($(THEOS_PACKAGE_SCHEME),)
AGGREGATE_BUILD := 1
  else
AGGREGATE_BUILD := 0
  endif
else
AGGREGATE_BUILD := 0
export THEOS_PACKAGE_SCHEME := $(SCHEME)
endif

ifeq ($(AGGREGATE_BUILD),1)
.DEFAULT_GOAL := package

.PHONY: all package clean clean-packages
all package::
	@echo "================================================"
	@echo "  [1/2] 構建 rootless (arm64)..."
	@echo "================================================"
	$(MAKE) SCHEME=rootless clean package
	@echo ""
	@echo "================================================"
	@echo "  [2/2] 構建 roothide (arm64e)..."
	@echo "================================================"
	$(MAKE) SCHEME=roothide clean package
	@echo ""
	@echo "================================================"
	@echo "  全部構建完成！"
	@echo "================================================"
	@ls -la packages/*.deb 2>/dev/null || echo "  (未找到 deb 檔案)"

clean::
	$(MAKE) SCHEME=rootless clean
	$(MAKE) SCHEME=roothide clean

clean-packages::
	@rm -f packages/com.huayuarc.systempro_*.deb
	@rm -rf packages/com.huayuarc.systempro_*

else

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Systempro SystemproUnseen SystemproUI

Systempro_FILES = Tweak.xm
Systempro_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-objc-protocol-method-implementation
Systempro_CFLAGS += -Wno-int-to-void-pointer-cast -Wno-cast-function-type -Wno-unused-function
Systempro_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore IOKit CoreTelephony
Systempro_PRIVATE_FRAMEWORKS = AppSupport

SystemproUI_FILES = SystemproUI.xm
SystemproUI_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
SystemproUI_FRAMEWORKS = UIKit Foundation
SystemproUI_LIBRARIES = MobileGestalt

SystemproUnseen_FILES = SystemproUnseen.mm
SystemproUnseen_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/include
SystemproUnseen_LDFLAGS = -L$(THEOS_PROJECT_DIR)/lib
SystemproUnseen_LIBRARIES = dobby substrate
SystemproUnseen_FRAMEWORKS = Foundation CoreFoundation

BUNDLE_NAME = LSILLSettings
LSILLSettings_FILES = Settings/LLRootListController.m
LSILLSettings_CFLAGS = -fobjc-arc
LSILLSettings_FRAMEWORKS = UIKit
LSILLSettings_PRIVATE_FRAMEWORKS = Preferences
LSILLSettings_INSTALL_PATH = /Library/PreferenceBundles

# roothide 需連結 libroothide
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
Systempro_LDFLAGS += -lroothide
SystemproUnseen_LDFLAGS += -lroothide
SystemproUI_LDFLAGS += -lroothide
LSILLSettings_LDFLAGS += -lroothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

INSTALL_TARGET_PROCESSES := SpringBoard backboardd

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences" \
		"$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle" \
		"$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/entry.plist \
		"$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/LSILLSettings.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Root.plist Settings/Notification.plist Settings/Disable.plist \
		Settings/System.plist Settings/Unseen.plist Settings/IPad.plist Settings/Info.plist \
		"$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Systempro@2x.png Settings/Systempro@3x.png \
		"$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)

after-install::
	$(ECHO_NOTHING)echo "[Systempro] 安裝完成！SpringBoard/backboardd 即將自動重啟使插件生效。"$(ECHO_END)

# 修正 deb Architecture 字段
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
before-package::
	$(ECHO_NOTHING)perl -pi -e 's/^Architecture:.*/Architecture: iphoneos-arm64e/' \
		"$(THEOS_STAGING_DIR)/DEBIAN/control"$(ECHO_END)
endif

endif
