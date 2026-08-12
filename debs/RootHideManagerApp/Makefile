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
	RootHide/PluginConfigViewController.m \
	RootHide/DeepCleanController.m \
	RootHide/VarCleanController.m \
	RootHide/UIComponent/ZFCheckbox.m \
	RootHide/NSJSONSerialization+Comments.m \
	RootHide/AppDataCleaner/AppDataCleaner.m
RootHide_FRAMEWORKS = UIKit Foundation CoreFoundation CFNetwork MobileCoreServices IOKit
RootHide_LIBRARIES = z
RootHide_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error -IRootHide -IRootHide/UIComponent
RootHide_INSTALL_PATH = /Applications
RootHide_INFO_PLIST = RootHide/Info.plist
RootHide_CODESIGN_FLAGS = -SRootHide.entitlements
RootHide_RESOURCE_FILES = RootHide/Assets.car RootHide/AppIcon60x60@2x.png RootHide/AppIcon76x76@2x~ipad.png

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
RootHide_LDFLAGS += -LRootHide/roothide -lroothide
else
RootHide_CFLAGS += -DROOTHIDE_USE_STUB=1
endif

include $(THEOS_MAKE_PATH)/application.mk

before-all::
	echo "#define VARCLEANRULESHASH" $$(cksum -o 3 RootHide/VarCleanRules.json | awk '{print $$1}') > RootHide/VarCleanRules.h

internal-stage::
	cp RootHide/VarCleanRules.json "$(THEOS_STAGING_DIR)/Applications/RootHide.app/varCleanRules.json"
	cp RootHide/Info.plist "$(THEOS_STAGING_DIR)/Applications/RootHide.app/Info.plist"
	printf 'APPL????' > "$(THEOS_STAGING_DIR)/Applications/RootHide.app/PkgInfo"
	for lang in ar de en fr it ja vi zh_CN; do \
		mkdir -p "$(THEOS_STAGING_DIR)/Applications/RootHide.app/$$lang.lproj"; \
		cp "RootHide/$$lang.lproj/Localizable.strings" "$(THEOS_STAGING_DIR)/Applications/RootHide.app/$$lang.lproj/Localizable.strings"; \
	done


after-install::
	install.exec 'uiopen -b com.roothide.manager'
