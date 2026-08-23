TARGET := iphone:clang:16.5:14.0
FINALPACKAGE = 1
# TWEAK_NAME marker: CI discovers this binary-preserving package project.

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
EV_ARCH := arm64e
else
EV_ARCH := arm64
endif

include $(THEOS)/makefiles/common.mk

# Preserve the supplied implementation, preference panel and resources byte-for-byte.
# Rootless packages use the original fat binaries at /var/jb; RootHide receives
# arm64e-only binaries at its hidden-root /Library paths.
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
before-package::
	@for binary in \
		"$(THEOS_PROJECT_DIR)/layout/Library/MobileSubstrate/DynamicLibraries/Evanesco.dylib" \
		"$(THEOS_PROJECT_DIR)/layout/Library/PreferenceBundles/Evanesco.bundle/Evanesco" \
		"$(THEOS_PROJECT_DIR)/layout/Library/ControlCenter/Bundles/evanescocc.bundle/evanescocc"; do \
		out="$$binary.thin"; \
		xcrun lipo "$$binary" -thin arm64e -output "$$out"; \
		mv "$$out" "$$binary"; chmod 755 "$$binary"; \
	done
endif

include $(THEOS_MAKE_PATH)/aggregate.mk
