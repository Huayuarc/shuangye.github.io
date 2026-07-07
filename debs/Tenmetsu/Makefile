THEOS_PACKAGE_SCHEME = rootless
TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
export ARCHS
ADDITIONAL_OBJCFLAGS = -fobjc-arc

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = tenmetsu
tenmetsu_FILES = Tweak.x
tenmetsu_CFLAGS = -fobjc-arc
tenmetsu_LIBRARIES = substrate
tenmetsu_FRAMEWORKS = UIKit Foundation CoreGraphics AudioToolbox

BUNDLE_NAME = Tenprefs
Tenprefs_FILES = Prefs/TENRootListController.m
Tenprefs_INSTALL_PATH = /Library/PreferenceBundles
Tenprefs_CFLAGS = -fobjc-arc
Tenprefs_FRAMEWORKS = UIKit Foundation
Tenprefs_PRIVATE_FRAMEWORKS = Preferences
Tenprefs_RESOURCE_FILES = Prefs/Info.plist Prefs/Root.plist Prefs/2.png Prefs/3.png Prefs/header@2x.png Prefs/twitter@2x.png Prefs/yobun@2x.png Prefs/onlyyou@2x.png Prefs/escape@2x.png Prefs/fastls@2x.png Prefs/icon.png Prefs/icon@2x.png Prefs/icon@3x.png

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 SpringBoard Preferences"
