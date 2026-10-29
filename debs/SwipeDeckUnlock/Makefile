ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard Preferences
FINALPACKAGE = 1

TWEAK_NAME = SwipeDeckUnlock
SwipeDeckUnlock_FILES = Tweak.xm
SwipeDeckUnlock_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DCPUTHERMAL_STRIP_LOGS=1
SwipeDeckUnlock_LDFLAGS = -Wl,-x -Wl,-dead_strip

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

# --- Scheme-aware DEB packaging ---
# THEOS_PACKAGE_SCHEME=rootless  -> iphoneos-arm64, paths under /var/jb/...
# THEOS_PACKAGE_SCHEME=roothide  -> iphoneos-arm64e, paths under /...
# Use `make package THEOS_PACKAGE_SCHEME=rootless` or `make package THEOS_PACKAGE_SCHEME=roothide`

SWIPEDECKUNLOCK_PACKAGE_NAME ?= com.huayuarc.swipedeckunlock
SWIPEDECKUNLOCK_PACKAGE_VERSION ?= 1.0.0
SWIPEDECKUNLOCK_PACKAGE_DIR ?= packages

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
SWIPEDECKUNLOCK_ARCH = iphoneos-arm64
SWIPEDECKUNLOCK_CONTROL = layout/DEBIAN/control.rootless
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
SWIPEDECKUNLOCK_ARCH = iphoneos-arm64e
SWIPEDECKUNLOCK_CONTROL = layout/DEBIAN/control.roothide
else
SWIPEDECKUNLOCK_ARCH = iphoneos-arm64
SWIPEDECKUNLOCK_CONTROL = layout/DEBIAN/control.rootless
$(warning [SwipeDeckUnlock] No THEOS_PACKAGE_SCHEME specified, defaulting to rootless/iphoneos-arm64)
endif

SWIPEDECKUNLOCK_DEB = $(SWIPEDECKUNLOCK_PACKAGE_DIR)/$(SWIPEDECKUNLOCK_PACKAGE_NAME)_$(SWIPEDECKUNLOCK_PACKAGE_VERSION)_$(SWIPEDECKUNLOCK_ARCH).deb

.PHONY: package-rootless package-roothide package-all clean-packages

package-rootless:
	@echo "[SwipeDeckUnlock] Building rootless package (iphoneos-arm64)..."
	THEOS_PACKAGE_SCHEME=rootless $(MAKE) package THEOS_PACKAGE_SCHEME=rootless

package-roothide:
	@echo "[SwipeDeckUnlock] Building roothide package (iphoneos-arm64e)..."
	THEOS_PACKAGE_SCHEME=roothide $(MAKE) package THEOS_PACKAGE_SCHEME=roothide

package-all: package-rootless package-roothide

clean-packages:
	rm -rf $(SWIPEDECKUNLOCK_PACKAGE_DIR)/*.deb

# Post-processing: after Theos builds the raw deb, regenerate postinst with
# scheme-specific paths and re-pack. See build-debs.sh for the full pipeline.
