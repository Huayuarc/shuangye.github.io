export TARGET = iphone:clang:latest:15.0
FINALPACKAGE = 1

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
  ARCHS = arm64e
else
  ARCHS = arm64
  export THEOS_PACKAGE_SCHEME ?= rootless
endif

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += tweak
SUBPROJECTS += prefs

include $(THEOS)/makefiles/aggregate.mk

# CI discovery marker: TWEAK_NAME is defined in tweak/Makefile.
