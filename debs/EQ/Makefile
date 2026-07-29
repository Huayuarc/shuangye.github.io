export TARGET = iphone:clang:16.5:15.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless

ifndef THEOS
THEOS := /var/mobile/theos
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = EarthquakeAlertUI
EarthquakeAlertUI_FILES = Tweak.x
EarthquakeAlertUI_CFLAGS = -fobjc-arc -I.
EarthquakeAlertUI_FRAMEWORKS = UIKit Foundation QuartzCore AudioToolbox
EarthquakeAlertUI_PRIVATE_FRAMEWORKS = SpringBoardServices

TOOL_NAME = eqd
eqd_FILES = daemon_src/eqdaemon.m
eqd_CFLAGS = -fobjc-arc -I.
eqd_CODESIGN_FLAGS = -S/tmp/eq-entitlements.plist
eqd_FRAMEWORKS = Foundation UIKit CoreGraphics UserNotifications
eqd_INSTALL_PATH = /usr/libexec

BUNDLE_NAME = EQPrefs
EQPrefs_FILES = EQPrefs/EQRootListController.m
EQPrefs_INSTALL_PATH = /Library/PreferenceBundles
EQPrefs_CFLAGS = -fobjc-arc -I.
EQPrefs_FRAMEWORKS = UIKit Foundation Preferences
EQPrefs_RESOURCE_DIRS = EQPrefs/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "launchctl unload /var/jb/Library/LaunchDaemons/com.shuangye.earthquake.plist 2>/dev/null ; launchctl load /var/jb/Library/LaunchDaemons/com.shuangye.earthquake.plist"
	install.exec "killall -9 SpringBoard"
