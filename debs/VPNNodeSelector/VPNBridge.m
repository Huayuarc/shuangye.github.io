#import "VPNBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static id VPNController(void) {
    static id controller;
    static id rootController;
    static void *image;
    @synchronized(NSObject.class) {
        if (!image) image = dlopen("/System/Library/PreferenceBundles/VPNPreferences.bundle/VPNPreferences", RTLD_LAZY | RTLD_LOCAL);
        if (!controller) {
            Class rootClass = objc_getClass("PSRootController");
            SEL rootInit = NSSelectorFromString(@"initWithTitle:identifier:");
            if (rootClass && [rootClass instancesRespondToSelector:rootInit]) {
                id value = ((id (*)(id, SEL))objc_msgSend)(rootClass, @selector(alloc));
                rootController = ((id (*)(id, SEL, id, id))objc_msgSend)(value, rootInit, @"Preferences", @"com.apple.Preferences");
            }
            Class cls = objc_getClass("VPNBundleController");
            SEL initSelector = NSSelectorFromString(@"initWithParentListController:");
            if (cls && [cls instancesRespondToSelector:initSelector]) {
                id value = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(alloc));
                controller = ((id (*)(id, SEL, id))objc_msgSend)(value, initSelector, nil);
                for (NSString *name in @[@"setRootController:", @"setParentController:"]) {
                    SEL selector = NSSelectorFromString(name);
                    if (rootController && [controller respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(controller, selector, rootController);
                }
            }
        }
    }
    return controller;
}

static id VPNControllerSpecifier(id controller) {
    if (!controller) return nil;
    @try {
        Ivar ivar = class_getInstanceVariable([controller class], "_vpnSpecifier");
        if (ivar) return object_getIvar(controller, ivar);
    } @catch (__unused NSException *exception) {}
    return nil;
}

BOOL VPNLegacyIsActive(void) {
    id controller = VPNController();
    SEL selector = NSSelectorFromString(@"vpnActiveForSpecifier:");
    if (!controller || ![controller respondsToSelector:selector]) return NO;
    @try {
        id value = ((id (*)(id, SEL, id))objc_msgSend)(controller, selector, VPNControllerSpecifier(controller));
        return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
    } @catch (__unused NSException *exception) { return NO; }
}

BOOL VPNLegacySetActive(BOOL active) {
    id controller = VPNController();
    if (!controller) return NO;
    @try {
        SEL direct = NSSelectorFromString(@"_setVPNActive:");
        if ([controller respondsToSelector:direct]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, direct, active);
            return YES;
        }
        SEL withSpecifier = NSSelectorFromString(@"setVPNActive:forSpecifier:");
        if ([controller respondsToSelector:withSpecifier]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(controller, withSpecifier, @(active), VPNControllerSpecifier(controller));
            return YES;
        }
        SEL legacy = NSSelectorFromString(@"setVPNActive:");
        if ([controller respondsToSelector:legacy]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, legacy, active);
            return YES;
        }
    } @catch (__unused NSException *exception) {}
    return NO;
}

BOOL VPNLegacyToggle(void) { return VPNLegacySetActive(!VPNLegacyIsActive()); }
