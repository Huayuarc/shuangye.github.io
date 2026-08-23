TARGET := iphone:clang:16.5:14.0
FINALPACKAGE = 1
# TWEAK_NAME marker: CI discovers this binary-preserving package project.

include $(THEOS)/makefiles/common.mk

# Preserve all supplied fat Mach-O binaries, the preference panel, resources,
# class names, selectors and configuration keys. The original arm64e slice was
# built with the legacy iOS 14 ABI; RootHide therefore needs its ABI shim.
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
before-package::
	@sed -i '' 's/^Depends: /Depends: oldabi, /' "$(THEOS_STAGING_DIR)/DEBIAN/control"
endif

include $(THEOS_MAKE_PATH)/aggregate.mk
