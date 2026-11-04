TWEAK_NAME = CCSIMFix

CCSIMFix_FILES = Tweak.m
CCSIMFix_CFLAGS = -fno-objc-arc
CCSIMFix_FRAMEWORKS = Foundation
# MSHookMessageEx 在运行时用 dlsym 取，不需要链接 substrate。

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
