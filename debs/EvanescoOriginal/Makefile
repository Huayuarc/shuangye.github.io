TARGET := iphone:clang:16.5:14.0
FINALPACKAGE = 1

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
EV_ARCH := arm64e
else
EV_ARCH := arm64
endif

include $(THEOS)/makefiles/common.mk

# Keep the supplied implementation, panel, resources and configuration intact.
# Only regenerate the package layout and select the ABI required by each scheme.
before-package::
	@rm -rf "$(THEOS_PROJECT_DIR)/layout"
	@cp -R "$(THEOS_PROJECT_DIR)/payload" "$(THEOS_PROJECT_DIR)/layout"
	@for binary in \
		"$(THEOS_PROJECT_DIR)/layout/Library/MobileSubstrate/DynamicLibraries/Evanesco.dylib" \
		"$(THEOS_PROJECT_DIR)/layout/Library/PreferenceBundles/Evanesco.bundle/Evanesco" \
		"$(THEOS_PROJECT_DIR)/layout/Library/ControlCenter/Bundles/evanescocc.bundle/evanescocc"; do \
		out="$$binary.thin"; \
		xcrun lipo "$$binary" -thin "$(EV_ARCH)" -output "$$out"; \
		mv "$$out" "$$binary"; chmod 755 "$$binary"; \
	done

include $(THEOS_MAKE_PATH)/aggregate.mk
