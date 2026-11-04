TWEAK_NAME = CCSIMGuard

CCSIMGuard_FILES = Tweak.m
CCSIMGuard_CFLAGS = -fno-objc-arc
CCSIMGuard_FRAMEWORKS = Foundation
# MSHookMessageEx 在运行时用 dlsym 取，不需要链接 substrate。
# layout/ 里带着 CCSIM 的模块 bundle 与 CCSIMTool，一起打进同一个 deb。

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
