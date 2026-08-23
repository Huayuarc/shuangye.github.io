TARGET := iphone:clang:16.5:14.0
FINALPACKAGE = 1
# TWEAK_NAME marker: CI discovers this binary-preserving package project.

include $(THEOS)/makefiles/common.mk

# RootHide host processes are arm64e-only. Start from the supplied ordinary
# arm64 slice, mark it as modern PAC arm64e, then ad-hoc sign the result.
# This keeps the original implementation/panel while avoiding legacy oldabi.
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
before-package::
	@for binary in \
		"$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/Evanesco.dylib" \
		"$(THEOS_STAGING_DIR)/Library/PreferenceBundles/Evanesco.bundle/Evanesco" \
		"$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/evanescocc.bundle/evanescocc"; do \
		out="$$binary.modern"; \
		xcrun lipo "$$binary" -thin arm64 -output "$$out"; \
		python3 "$(THEOS_PROJECT_DIR)/scripts/modern_arm64e.py" "$$out"; \
		ldid -S "$$out"; \
		mv "$$out" "$$binary"; chmod 755 "$$binary"; \
	done
endif

include $(THEOS_MAKE_PATH)/aggregate.mk
