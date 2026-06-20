DEBUG := 0
FINALPACKAGE := 1
export THEOS := /var/mobile/theos
export ARCHS := arm64 arm64e
TARGET := iphone:clang:16.5:14.0

# ========== 自动检测 jbroot 路径并传入代码 ==========
JBROOT_DIR != ls -d /var/mobile/Containers/Shared/AppGroup/.jbroot-* 2>/dev/null | head -1
ifneq ($(JBROOT_DIR),)
Systempro_CFLAGS += -DJBROOT_PATH=\"$(JBROOT_DIR)\"
LSILLSettings_CFLAGS += -DJBROOT_PATH=\"$(JBROOT_DIR)\"
endif
# 代码中可用: @(JBROOT_PATH "/Library/xxx") 或 strcpy(buf, JBROOT_PATH);

# ========== 双方案构建 ==========
# make              → 构建 rootless (默认)
# make SCHEME=roothide → 构建 roothide
# make build-all    → 同时构建 rootless + roothide

ifeq ($(SCHEME),roothide)
export THEOS_PACKAGE_SCHEME := roothide
else
export THEOS_PACKAGE_SCHEME := rootless
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Systempro
Systempro_FILES = Tweak.xm
Systempro_CFLAGS = -fobjc-arc
Systempro_FRAMEWORKS = UIKit Foundation

BUNDLE_NAME = LSILLSettings
LSILLSettings_FILES = Settings/LLRootListController.m
LSILLSettings_CFLAGS = -fobjc-arc
LSILLSettings_FRAMEWORKS = UIKit
LSILLSettings_PRIVATE_FRAMEWORKS = Preferences
LSILLSettings_INSTALL_PATH = /Library/PreferenceBundles

# roothide 需要链接 libroothide
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
Systempro_LDFLAGS += -lroothide
LSILLSettings_LDFLAGS += -lroothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

INSTALL_TARGET_PROCESSES := SpringBoard

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences" "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/LSILLSettings.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Root.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Systempro@2x.png "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Systempro@3x.png "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LSILLSettings.bundle/"$(ECHO_END)

after-install::
	$(ECHO_NOTHING)echo "[Systempro] 安装完成！SpringBoard 即将自动重启使插件生效。"$(ECHO_END)

# 修正 deb 包 Architecture 字段（适配双方案）
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
before-package::
	$(ECHO_NOTHING)sed -i 's/^Architecture:.*/Architecture: iphoneos-arm64e/' "$(THEOS_STAGING_DIR)/DEBIAN/control"$(ECHO_END)
endif

# ========== build-all：同时输出两个 deb ==========
PACKAGE_DIR = ./packages

build-all::
	@echo "================================================"
	@echo "  [1/2] 构建 rootless 版本..."
	@echo "================================================"
	$(MAKE) clean
	$(MAKE)
	$(MAKE) package
	@echo ""
	@echo "================================================"
	@echo "  [2/2] 构建 roothide 版本..."
	@echo "================================================"
	$(MAKE) clean
	$(MAKE) SCHEME=roothide
	$(MAKE) package SCHEME=roothide
	@echo ""
	@echo "================================================"
	@echo "  全部构建完成！"
	@echo "================================================"
	@echo "生成的文件:"
	@ls -la $(PACKAGE_DIR)/*.deb 2>/dev/null || echo "  (未找到 deb 文件)"
