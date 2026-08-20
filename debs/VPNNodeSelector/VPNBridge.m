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

static id VPNSafeConnectionStore(void) {
    VPNController();
    Class cls = objc_getClass("VPNConnectionStore");
    SEL selector = NSSelectorFromString(@"sharedInstance");
    if (!cls || ![cls respondsToSelector:selector]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(cls, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

id VPNSafeCurrentIdentifierForGrade(NSInteger grade) {
    id store = VPNSafeConnectionStore();
    SEL selector = NSSelectorFromString(@"activeVPNIDWithGrade:");
    if (!store || ![store respondsToSelector:selector]) return nil;
    @try { return ((id (*)(id, SEL, NSInteger))objc_msgSend)(store, selector, grade); }
    @catch (__unused NSException *exception) { return nil; }
}

BOOL VPNSafeSetCurrentIdentifier(id identifier, NSInteger grade) {
    if (!identifier) return NO;
    id store = VPNSafeConnectionStore();
    SEL selector = NSSelectorFromString(@"setActiveVPNID:withGrade:");
    if (!store || ![store respondsToSelector:selector]) return NO;
    @try {
        ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(store, selector, identifier, grade);
        id current = VPNSafeCurrentIdentifierForGrade(grade);
        return current ? [current isEqual:identifier] : YES;
    } @catch (__unused NSException *exception) { return NO; }
}

static void VPNEnsureSpecifiersLoaded(id controller) {
    if (!controller) return;
    @try {
        SEL selector = NSSelectorFromString(@"specifiersWithSpecifier:");
        if ([controller respondsToSelector:selector]) {
            ((id (*)(id, SEL, id))objc_msgSend)(controller, selector, VPNControllerSpecifier(controller));
        }
    } @catch (__unused NSException *exception) {}
}

static NSString *VPNSpecifierName(id specifier) {
    if (!specifier) return nil;
    @try {
        for (NSString *selName in @[@"name", @"title", @"identifier", @"propertyForKey:"]) {
            SEL sel = NSSelectorFromString(selName);
            if (![specifier respondsToSelector:sel]) continue;
            if ([selName isEqualToString:@"propertyForKey:"]) {
                for (NSString *key in @[@"label", @"name", @"title", @"id", @"identifier", @"serviceID", @"vpn-id"]) {
                    id value = ((id (*)(id, SEL, id))objc_msgSend)(specifier, sel, key);
                    if ([value isKindOfClass:NSString.class] && [value length]) return value;
                }
            } else {
                id value = ((id (*)(id, SEL))objc_msgSend)(specifier, sel);
                if ([value isKindOfClass:NSString.class] && [value length]) return value;
            }
        }
    } @catch (__unused NSException *exception) {}
    return nil;
}

NSArray *VPNSafeCurrentPersonalVPNSpecifiers(void) {
    id controller = VPNController();
    if (!controller) return nil;
    VPNEnsureSpecifiersLoaded(controller);
    SEL sel = NSSelectorFromString(@"currentPersonalVPNSpecifiers");
    if (![controller respondsToSelector:sel]) return nil;
    @try {
        id value = ((id (*)(id, SEL))objc_msgSend)(controller, sel);
        return [value isKindOfClass:NSArray.class] ? value : nil;
    } @catch (__unused NSException *exception) { return nil; }
}

NSString *VPNSafeCurrentSpecifierName(void) {
    NSArray *specifiers = VPNSafeCurrentPersonalVPNSpecifiers();
    for (id specifier in specifiers) {
        @try {
            SEL valueSel = NSSelectorFromString(@"propertyForKey:");
            BOOL checked = NO;
            if ([specifier respondsToSelector:valueSel]) {
                for (NSString *key in @[@"checked", @"isSelected", @"selected", @"current", @"value", @"enabled"]) {
                    id value = ((id (*)(id, SEL, id))objc_msgSend)(specifier, valueSel, key);
                    if ([value respondsToSelector:@selector(boolValue)] && [value boolValue]) { checked = YES; break; }
                }
            }
            if (!checked) {
                for (NSString *selName in @[@"isChecked", @"checked", @"isSelected", @"selected"]) {
                    SEL sel = NSSelectorFromString(selName);
                    if ([specifier respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(specifier, sel)) { checked = YES; break; }
                }
            }
            if (checked) return VPNSpecifierName(specifier);
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

BOOL VPNSafeSelectPersonalVPNSpecifierNamed(NSString *name) {
    if (name.length == 0) return NO;
    id controller = VPNController();
    NSArray *specifiers = VPNSafeCurrentPersonalVPNSpecifiers();
    if (!controller || specifiers.count == 0) return NO;
    for (id specifier in specifiers) {
        NSString *specName = VPNSpecifierName(specifier);
        if (![specName isEqualToString:name]) continue;
        @try {
            for (NSString *selName in @[@"setPreferenceValue:specifier:", @"selectSpecifier:", @"handleSelectSpecifier:", @"tableView:didSelectRowAtIndexPath:"]) {
                SEL sel = NSSelectorFromString(selName);
                if (![controller respondsToSelector:sel]) continue;
                if ([selName isEqualToString:@"setPreferenceValue:specifier:"]) {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(controller, sel, @YES, specifier);
                    return YES;
                }
                if ([selName isEqualToString:@"selectSpecifier:"] || [selName isEqualToString:@"handleSelectSpecifier:"]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(controller, sel, specifier);
                    return YES;
                }
            }
        } @catch (__unused NSException *exception) {}
        return NO;
    }
    return NO;
}
