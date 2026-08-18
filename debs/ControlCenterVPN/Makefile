TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

# CI 分别生成 Dopamine/rootless arm64 与 RootHide arm64e 单切片包。
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
ARCHS = arm64
else
ARCHS = arm64e
endif

include $(THEOS)/makefiles/common.mk

# 空加载器使现有 GitHub 工作流识别此 Bundle 工程并产出 DEB。
TWEAK_NAME = VPNControlCenterLoader
VPNControlCenterLoader_FILES = VPNControlCenterLoader.xm
VPNControlCenterLoader_CFLAGS = -fobjc-arc -fvisibility=hidden
VPNControlCenterLoader_LDFLAGS = -Wl,-x -Wl,-dead_strip

BUNDLE_NAME = VPNControlCenter
VPNControlCenter_FILES = VPNControlCenterModule.m VPNControlCenterModuleViewController.m
VPNControlCenter_FRAMEWORKS = UIKit Foundation NetworkExtension
VPNControlCenter_PRIVATE_FRAMEWORKS = ControlCenterUIKit
VPNControlCenter_CFLAGS = -fobjc-arc -fvisibility=hidden
VPNControlCenter_LDFLAGS = -Wl,-x -Wl,-dead_strip
VPNControlCenter_INSTALL_PATH = /Library/ControlCenter/Bundles

FINALPACKAGE = 1
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
