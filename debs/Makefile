TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
export ARCHS

THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Jade
Jade_FILES = Tweak.x \
             JadeWeatherHandler.m \
             JadeMainViewController.m \
             JadeCardViewController.m \
             AmpereSupport_UIBatteryView.m \
             JadeBatteryPill.m \
             JadeTimePill.m \
             JadeBrightnessSlider.m \
             JadeVolumeSlider.m \
             JadeBatteryDevice.m \
             JadeBatteryModule.m \
             JadeCurrentUptimeModule.m \
             JadeFavoriteModulesCaddy.m \
             JadeFullWidthModule.m \
             JadeMainModulesCaddy.m \
             JadeMediaModule.m \
             JadePowerModuleButton.m \
             JadePowerModule.m \
             JadeSmallModule.m \
             JadeWeatherModule.m \
             JadeConnectivityButton.m \
             JadeConnectivityModule.m \
             JadeSlidersModule.m

Jade_CFLAGS = -fobjc-arc
Jade_BUNDLE_RESOURCE_DIRS = JadeLocalization.bundle
Jade_FRAMEWORKS = UIKit Foundation CoreGraphics MediaPlayer MediaToolbox AudioToolbox AVFoundation CoreLocation
Jade_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += JadePrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences
	cp JadePrefs.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/JadePrefs.plist
