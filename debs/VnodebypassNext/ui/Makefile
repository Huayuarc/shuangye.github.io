TARGET := iphone:clang:16.5:15.0
override ARCHS = arm64
override THEOS_PACKAGE_SCHEME = rootless
FINALPACKAGE = 1
include $(THEOS)/makefiles/common.mk
APPLICATION_NAME = vnodebypass
vnodebypass_FILES = App.m
vnodebypass_CFLAGS = -fobjc-arc -fblocks -fvisibility=hidden -Os
vnodebypass_LDFLAGS = -Wl,-x -Wl,-dead_strip
vnodebypass_FRAMEWORKS = UIKit Foundation CoreFoundation CoreGraphics
vnodebypass_CODESIGN_FLAGS = -S../app-entitlements.plist
vnodebypass_INFOPLIST = App-Info.plist
include $(THEOS_MAKE_PATH)/application.mk
BUNDLE_NAME = VBModule
VBModule_FILES = VBModule.m
VBModule_INFOPLIST = VBModule-Info.plist
VBModule_RESOURCE_DIRS = CCResources
VBModule_CFLAGS = -fobjc-arc -fblocks -fvisibility=hidden -Os
VBModule_LDFLAGS = -Wl,-undefined,dynamic_lookup -Wl,-x -Wl,-dead_strip
VBModule_FRAMEWORKS = UIKit Foundation CoreFoundation
VBModule_INSTALL_PATH = /Library/ControlCenter/Bundles
VBModule_BUNDLE_EXTENSION = bundle
include $(THEOS_MAKE_PATH)/bundle.mk
