#import "VPNBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static id VPNController(void) {
    static id controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PreferenceBundles/VPNPreferences.bundle/VPNPreferences", RTLD_LAZY);
        Class cls = objc_getClass("VPNBundleController");
        SEL initSelector = NSSelectorFromString(@"initWithParentListController:");
        if (cls && [cls instancesRespondToSelector:initSelector]) {
            id value = [cls alloc];
            controller = ((id (*)(id, SEL, id))objc_msgSend)(value, initSelector, nil);
        }
    });
    return controller;
}

BOOL VPNLegacyIsActive(void) {
    id controller = VPNController();
    SEL selector = NSSelectorFromString(@"vpnActiveForSpecifier:");
    if (!controller || ![controller respondsToSelector:selector]) return NO;
    id value = ((id (*)(id, SEL, id))objc_msgSend)(controller, selector, nil);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

void VPNLegacyToggle(void) {
    id controller = VPNController();
    SEL selector = NSSelectorFromString(@"setVPNActive:");
    if (!controller || ![controller respondsToSelector:selector]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, selector, !VPNLegacyIsActive());
}
