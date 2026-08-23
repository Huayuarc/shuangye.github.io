TARGET := iphone:clang:16.5:14.0
FINALPACKAGE = 1
# TWEAK_NAME marker: CI discovers this binary-preserving package project.

include $(THEOS)/makefiles/common.mk

# Preserve the supplied implementation, preference panel, resources and keys.
# For RootHide, thin the staged payload after Theos copies layout and before
# the package scheme moves it into the hidden-root /Library hierarchy.
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
before-package::
	@for binary in \
		"$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/Evanesco.dylib" \
		"$(THEOS_STAGING_DIR)/Library/PreferenceBundles/Evanesco.bundle/Evanesco" \
		"$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/evanescocc.bundle/evanescocc"; do \
		out="$$binary.thin"; \
		xcrun lipo "$$binary" -thin arm64e -output "$$out"; \
		mv "$$out" "$$binary"; chmod 755 "$$binary"; \
	done
endif

include $(THEOS_MAKE_PATH)/aggregate.mk
