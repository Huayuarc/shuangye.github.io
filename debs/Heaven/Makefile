TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
export ARCHS

THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Heaven
Heaven_FILES = Heaven.xm
Heaven_CFLAGS = -fobjc-arc -Wno-unused-function
Heaven_FRAMEWORKS = UIKit CoreLocation CoreTelephony AdSupport AppTrackingTransparency SystemConfiguration WebKit Security
Heaven_PRIVATE_FRAMEWORKS = AppSupport
Heaven_LIBRARIES = substrate

BUNDLE_NAME = HeavenPrefs
HeavenPrefs_FILES = prefs/HeavenPrefs.m prefs/HFeedbackViewController.m
HeavenPrefs_CFLAGS = -fobjc-arc
HeavenPrefs_RESOURCE_FILES = prefs/Info.plist prefs/Root.plist resources/icon.png resources/icon@2x.png resources/icon@3x.png resources/HeavenLogo.png
HeavenPrefs_FRAMEWORKS = UIKit
HeavenPrefs_PRIVATE_FRAMEWORKS = Preferences
HeavenPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 Preferences"
