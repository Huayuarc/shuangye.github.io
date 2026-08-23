TARGET := iphone:clang:16.5:14.0
FINALPACKAGE = 1
# TWEAK_NAME marker: CI discovers this binary-preserving package project.

include $(THEOS)/makefiles/common.mk

# The supplied fat binaries contain a legacy iOS 14 arm64e slice and a normal
# arm64 slice. RootHide's package architecture remains iphoneos-arm64e, while
# the staged Mach-O payload is thinned to arm64 to avoid the legacy ABI shim.
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
before-package::
	@for binary in \
		"$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/Evanesco.dylib" \
		"$(THEOS_STAGING_DIR)/Library/PreferenceBundles/Evanesco.bundle/Evanesco" \
		"$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/evanescocc.bundle/evanescocc"; do \
		out="$$binary.arm64"; \
		xcrun lipo "$$binary" -thin arm64 -output "$$out"; \
		mv "$$out" "$$binary"; chmod 755 "$$binary"; \
	done
endif

include $(THEOS_MAKE_PATH)/aggregate.mk
