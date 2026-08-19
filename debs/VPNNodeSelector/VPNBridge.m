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

static id VPNStore(void) {
    id controller = VPNController();
    static BOOL prepared;
    if (controller && !prepared) {
        prepared = YES;
        @try {
            SEL prepare = NSSelectorFromString(@"specifiersWithSpecifier:");
            if ([controller respondsToSelector:prepare]) ((id (*)(id, SEL, id))objc_msgSend)(controller, prepare, nil);
        } @catch (__unused NSException *exception) {}
    }
    @try {
        Ivar ivar = controller ? class_getInstanceVariable([controller class], "_store") : NULL;
        id controllerStore = ivar ? object_getIvar(controller, ivar) : nil;
        if (controllerStore) return controllerStore;
    } @catch (__unused NSException *exception) {}
    Class cls = objc_getClass("VPNConnectionStore");
    SEL selector = NSSelectorFromString(@"sharedInstance");
    if (!cls || ![cls respondsToSelector:selector]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(cls, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

NSArray<NSDictionary *> *VPNLegacyCopyNodes(void) {
    id store = VPNStore();
    if (!store) return @[];
    @try {
        SEL reload = NSSelectorFromString(@"reloadVPN");
        if ([store respondsToSelector:reload]) ((void (*)(id, SEL))objc_msgSend)(store, reload);
    } @catch (__unused NSException *exception) {}
    NSMutableArray<NSDictionary *> *nodes = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    SEL servicesSelector = NSSelectorFromString(@"vpnServicesForCurrentSetWithGrade:");
    SEL optionsSelector = NSSelectorFromString(@"optionsForServiceID:withGrade:");
    SEL activeSelector = NSSelectorFromString(@"activeVPNIDWithGrade:");
    SEL connectionSelector = NSSelectorFromString(@"connectionWithServiceID:withGrade:");
    if (![store respondsToSelector:servicesSelector]) return @[];
    for (NSUInteger grade = 0; grade <= 8; grade++) {
        @try {
            NSArray *services = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(store, servicesSelector, grade);
            id activeID = [store respondsToSelector:activeSelector] ? ((id (*)(id, SEL, NSUInteger))objc_msgSend)(store, activeSelector, grade) : nil;
            for (id service in services) {
                id serviceID = service;
                NSString *name = nil;
                if (![service isKindOfClass:NSString.class] && ![service isKindOfClass:NSUUID.class] && [service respondsToSelector:NSSelectorFromString(@"serviceID")]) {
                    serviceID = ((id (*)(id, SEL))objc_msgSend)(service, NSSelectorFromString(@"serviceID"));
                    if ([service respondsToSelector:NSSelectorFromString(@"displayName")]) name = ((id (*)(id, SEL))objc_msgSend)(service, NSSelectorFromString(@"displayName"));
                }
                if (!serviceID) continue;
                NSString *dedupeKey = [serviceID isKindOfClass:NSUUID.class] ? [serviceID UUIDString] : [serviceID description];
                if (!dedupeKey.length || [seen containsObject:dedupeKey]) continue;
                id connection = [store respondsToSelector:connectionSelector] ? ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(store, connectionSelector, serviceID, grade) : nil;
                if (!name.length && [connection respondsToSelector:NSSelectorFromString(@"displayName")]) name = ((id (*)(id, SEL))objc_msgSend)(connection, NSSelectorFromString(@"displayName"));
                NSDictionary *options = [store respondsToSelector:optionsSelector] ? ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(store, optionsSelector, serviceID, grade) : nil;
                for (NSString *key in @[@"UserDefinedName", @"DisplayName", @"displayName", @"name", @"Name"]) {
                    id value = [options isKindOfClass:NSDictionary.class] ? options[key] : nil;
                    if ([value isKindOfClass:NSString.class] && [value length]) { name = value; break; }
                }
                if (!name.length) {
                    SEL appSelector = NSSelectorFromString(@"appNameForServiceID:withGrade:");
                    if ([store respondsToSelector:appSelector]) name = ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(store, appSelector, serviceID, grade);
                }
                if (!name.length) name = dedupeKey;
                [seen addObject:dedupeKey];
                [nodes addObject:@{@"id":serviceID, @"name":name, @"grade":@(grade), @"active":@([activeID isEqual:serviceID])}];
            }
        } @catch (__unused NSException *exception) {}
    }
    return nodes.copy;
}

BOOL VPNLegacySelectNode(id serviceID, NSUInteger grade) {
    if (!serviceID) return NO;
    id store = VPNStore();
    SEL selector = NSSelectorFromString(@"setActiveVPNID:withGrade:");
    if (!store || ![store respondsToSelector:selector]) return NO;
    @try {
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(store, selector, serviceID, grade);
        SEL reload = NSSelectorFromString(@"reloadVPN");
        if ([store respondsToSelector:reload]) ((void (*)(id, SEL))objc_msgSend)(store, reload);
        return YES;
    } @catch (__unused NSException *exception) { return NO; }
}
