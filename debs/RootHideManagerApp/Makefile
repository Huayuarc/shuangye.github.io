ARCHS ?= arm64
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = RootHide
FINALPACKAGE ?= 1
DEBUG ?= 0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = RootHide

RootHide_FILES = \
	RootHide/main.m \
	RootHide/AppDelegate.m \
	RootHide/AppInfo.m \
	RootHide/BlacklistViewController.m \
	RootHide/SettingViewController.m \
	RootHide/VarCleanController.m \
	RootHide/UIComponent/ZFCheckbox.m \
	RootHide/NSJSONSerialization+Comments.m \
	RootHide/AppDataCleaner/AppDataCleaner.m
RootHide_FRAMEWORKS = UIKit Foundation CoreFoundation CFNetwork MobileCoreServices IOKit
RootHide_LIBRARIES = z
RootHide_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error -IRootHide -IRootHide/UIComponent
RootHide_INSTALL_PATH = /Applications
RootHide_INFO_PLIST = RootHide/Info.plist
RootHide_CODESIGN_FLAGS = -Sentitlements.plist
RootHide_RESOURCE_FILES = RootHide/Assets.car RootHide/VarCleanRules.json RootHide/AppIcon60x60@2x.png RootHide/AppIcon76x76@2x~ipad.png
RootHide_RESOURCE_DIRS = RootHide/ar.lproj RootHide/de.lproj RootHide/en.lproj RootHide/fr.lproj RootHide/it.lproj RootHide/ja.lproj RootHide/vi.lproj RootHide/zh_CN.lproj

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
RootHide_LDFLAGS += -LRootHide/roothide -lroothide
else
RootHide_CFLAGS += -DROOTHIDE_USE_STUB=1
endif

include $(THEOS_MAKE_PATH)/application.mk

before-all::
	echo "#define VARCLEANRULESHASH" $$(cksum -o 3 RootHide/VarCleanRules.json | awk '{print $$1}') > RootHide/VarCleanRules.h

before-package::
	ldid -M -S./nickchan.entitlements $(THEOS_STAGING_DIR)/Applications/RootHide.app/RootHide

after-install::
	install.exec 'uiopen -b com.roothide.manager'
