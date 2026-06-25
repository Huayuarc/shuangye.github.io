#===============================================================================
# CPUthermalCC Bundle Makefile
#===============================================================================

THEOS_PACKAGE_SCHEME = rootless
export THEOS_PACKAGE_SCHEME

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CPUthermalCC

CPUthermalCC_FILES = CPUthermalCCModule.m CPUthermalCCModuleViewController.m
CPUthermalCC_CFLAGS = -fobjc-arc
CPUthermalCC_FRAMEWORKS = Foundation UIKit ControlCenterUIKit
CPUthermalCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
CPUthermalCC_INSTALL_PATH = /Library/ControlCenter/Bundles/

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
install.exec "killall -9 SpringBoard"
