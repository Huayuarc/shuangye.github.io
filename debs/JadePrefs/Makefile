include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = JadePrefs
JadePrefs_FILES = JadeRootListController.m
JadePrefs_INSTALL_PATH = /Library/PreferenceBundles
JadePrefs_CFLAGS = -fobjc-arc
JadePrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
JadePrefs_RESOURCE_FILES = Root.plist Interface.plist Theming.plist ModuleConfiguration.plist \
                           ConnectivityConfiguration.plist SlidersConfiguration.plist \
                           MediaConfiguration.plist PowerConfiguration.plist \
                           FavoriteTogglesConfiguration.plist ConnectivityTheming.plist \
                           SlidersTheming.plist MediaTheming.plist PowerTheming.plist \
                           StockModulesTheming.plist CustomModulesTheming.plist \
                           IndicatorsTheming.plist WeatherTheming.plist UptimeTheming.plist \
                           zh-Hans.lproj zh_Hans.lproj \
                           ../icon@3.png ../bigicon.png
JadePrefs_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/bundle.mk
