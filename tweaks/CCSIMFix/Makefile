TWEAK_NAME = CCSIMFix

CCSIMFix_FILES = Tweak.m
CCSIMFix_CFLAGS = -fno-objc-arc
CCSIMFix_FRAMEWORKS = Foundation
# MSHookMessageEx 在运行时由注入器的 substrate 提供，构建时不需要链接。
CCSIMFix_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
