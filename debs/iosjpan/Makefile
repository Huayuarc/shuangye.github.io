DEBUG=0
FINALPACKAGE=1
THEOS_PACKAGE_SCHEME = rootless
THEOS ?= /var/mobile/theos

TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
export ARCHS

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = iOSKeyboardTheme
iOSKeyboardTheme_FILES = Tweak.xm
iOSKeyboardTheme_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = iOSKeyboardThemePrefs
iOSKeyboardThemePrefs_FILES = iOSKeyboardThemePrefs/iOSKeyboardThemePrefs.mm
iOSKeyboardThemePrefs_INSTALL_PATH = /Library/PreferenceBundles
iOSKeyboardThemePrefs_CFLAGS = -fobjc-arc
iOSKeyboardThemePrefs_FRAMEWORKS = UIKit Foundation
iOSKeyboardThemePrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 Preferences" || true
