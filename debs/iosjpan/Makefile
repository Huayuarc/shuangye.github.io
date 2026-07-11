DEBUG=0
FINALPACKAGE=1
THEOS_PACKAGE_SCHEME = rootless
THEOS = /var/mobile/theos

TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
export ARCHS

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = iOS主题键盘
iOS主题键盘_FILES = Tweak.xm
iOS主题键盘_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = iOS主题键盘Prefs
iOS主题键盘Prefs_FILES = iOS主题键盘Prefs/iOS主题键盘Prefs.mm
iOS主题键盘Prefs_INSTALL_PATH = /Library/PreferenceBundles
iOS主题键盘Prefs_CFLAGS = -fobjc-arc
iOS主题键盘Prefs_FRAMEWORKS = UIKit Foundation
iOS主题键盘Prefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 Preferences" || true
