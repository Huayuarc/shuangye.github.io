DEBUG := 0
FINALPACKAGE := 1
_THEOS_TOP_INVOCATION_DONE :=
export _THEOS_TOP_INVOCATION_DONE
ifeq ($(SCHEME),roothide)
  ifneq ($(wildcard /Users/colorblack/theos_roothide/*),)
    override THEOS := /Users/colorblack/theos_roothide
  endif
endif

ifeq ($(THEOS),)
  ifneq ($(wildcard /Users/colorblack/theos/*),)
    THEOS := /Users/colorblack/theos
  else
    THEOS := /var/mobile/theos
  endif
endif
export THEOS
export ARCHS := arm64 arm64e
TARGET := iphone:clang:16.5:14.0
# iOS on-device 编译需要指定 bash 路径；CI (macOS) 使用默认 /bin/sh
ifneq ($(wildcard /var/jb/bin/bash),)
SHELL := /var/jb/bin/bash
endif

# ========== 自动检测 jbroot 路径并传入代码 ==========
JBROOT_DIR := $(shell ls -d /var/mobile/Containers/Shared/AppGroup/.jbroot-* 2>/dev/null | head -1)
ifneq ($(JBROOT_DIR),)
Systempro_CFLAGS += -DJBROOT_PATH=\"$(JBROOT_DIR)\"
LSILLSettings_CFLAGS += -DJBROOT_PATH=\"$(JBROOT_DIR)\"
endif
# 代码中可用: @(JBROOT_PATH "/Library/xxx") 或 strcpy(buf, JBROOT_PATH);

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

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Systempro SystemproUnseen SystemproGestureSB SystemproGestureUI
Systempro_FILES = Tweak.xm \
	Tweak_Cyanide_HideHomeBar.x \
	Tweak_Cyanide_DSOTA.x \
	Tweak_Cyanide_CallRecordSound.x \
	Tweak_Cyanide_NanoRegistry.x
Systempro_CFLAGS += -fobjc-arc -Wno-deprecated-declarations -Wno-objc-protocol-method-implementation -Wno-int-to-void-pointer-cast -Wno-cast-function-type -Wno-unused-function
Systempro_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore IOKit CoreTelephony
Systempro_PRIVATE_FRAMEWORKS = AppSupport

SystemproUnseen_FILES = SystemproUnseen.mm
SystemproUnseen_CFLAGS += -fobjc-arc -I$(THEOS_PROJECT_DIR)/include
SystemproUnseen_LDFLAGS += -L$(THEOS_PROJECT_DIR)/lib
SystemproUnseen_LIBRARIES += dobby substrate
ifneq ($(wildcard /var/jb/usr/lib),)
SystemproUnseen_LDFLAGS += -L/var/jb/usr/lib
endif
SystemproUnseen_FRAMEWORKS = Foundation CoreFoundation

# ========== 手势插件 (移植自 HalFiPad) ==========
SystemproGestureSB_FILES = Tweak_GestureSB.xm
SystemproGestureSB_CFLAGS += -fobjc-arc
SystemproGestureSB_FRAMEWORKS = UIKit Foundation CoreGraphics

SystemproGestureUI_FILES = Tweak_GestureUI.xm
SystemproGestureUI_CFLAGS += -fobjc-arc
SystemproGestureUI_FRAMEWORKS = UIKit Foundation CoreGraphics
SystemproGestureUI_LIBRARIES = MobileGestalt

BUNDLE_NAME = LSILLSettings
LSILLSettings_FILES = Settings/LLRootListController.m
LSILLSettings_CFLAGS += -fobjc-arc
LSILLSettings_FRAMEWORKS = UIKit
LSILLSettings_PRIVATE_FRAMEWORKS = Preferences
LSILLSettings_INSTALL_PATH = /Library/PreferenceBundles

# roothide 需要链接 libroothide
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
Systempro_LDFLAGS += -lroothide
SystemproUnseen_LDFLAGS += -lroothide
SystemproGestureSB_LDFLAGS += -lroothide
SystemproGestureUI_LDFLAGS += -lroothide
LSILLSettings_LDFLAGS += -lroothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

INSTALL_TARGET_PROCESSES := SpringBoard backboardd

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)tmp$(THEOS_PACKAGE_INSTALL_PREFIX)"$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences" "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/LSILLSettings.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Root.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Notification.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Disable.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/System.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Unseen.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Gesture.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Systempro@2x.png "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Systempro@3x.png "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)
	# 安装手势插件过滤文件
	$(ECHO_NOTHING)cp SystemproGestureSB.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"$(ECHO_END)
	$(ECHO_NOTHING)cp SystemproGestureUI.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"$(ECHO_END)

after-install::
	$(ECHO_NOTHING)echo "[Systempro] 安装完成！SpringBoard/backboardd 即将自动重启使插件生效。"$(ECHO_END)

# 修正 deb 包 Architecture 字段（适配双方案）
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
before-package::
	$(ECHO_NOTHING)perl -pi -e 's/^Architecture:.*/Architecture: iphoneos-arm64e/' "$(THEOS_STAGING_DIR)/DEBIAN/control"$(ECHO_END)
endif

# ========== build-all：同时输出两个 deb ==========
PACKAGE_DIR = ./packages

build-all::
	@echo "================================================"
	@echo "  [1/2] 开始构建 rootless 版本..."
	@echo "================================================"
	$(MAKE) clean
	$(MAKE) package
	@echo ""
	@echo "================================================"
	@echo "  [2/2] 开始构建 roothide 版本..."
	@echo "================================================"
	@if [ -d "/Users/colorblack/theos_roothide/vendor/mod/roothide" ] || [ -d "/Users/colorblack/theos_roothide/mod/roothide" ] || [ -d "$(THEOS)/vendor/mod/roothide" ] || [ -d "$(THEOS)/mod/roothide" ]; then \
		$(MAKE) clean SCHEME=roothide; \
		$(MAKE) package SCHEME=roothide; \
	else \
		echo "  [提示] 当前 Theos 环境未配置 roothide 方案 (目录 /Users/colorblack/theos_roothide/mod/roothide 不存在)，已自动跳过 roothide 版本的构建。"; \
	fi
	@echo ""
	@echo "================================================"
	@echo "  全部构建完成！"
	@echo "================================================"
	@echo "生成的文件:"
	@ls -la $(PACKAGE_DIR)/*.deb 2>/dev/null || echo "  (未找到 deb 文件)"
