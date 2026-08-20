#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>

static NSString *const VPNSharedDomain = @"com.huayuarc.vpnnodeselector.shared";
static NSString *const VPNSelectedNameKey = @"SelectedName";
static NSString *const VPNRequestedNameKey = @"RequestedName";
static NSString *const VPNRequestedIdentifierKey = @"RequestedIdentifier";
static NSString *const VPNRequestedGradeKey = @"RequestedGrade";
static NSString *const VPNRequestNonceKey = @"RequestNonce";
static NSString *const VPNAckNonceKey = @"AckNonce";
static CFStringRef const VPNSelectionChangedNotification = CFSTR("com.huayuarc.vpnnodeselector.selection-changed");
static CFStringRef const VPNSelectionRequestNotification = CFSTR("com.huayuarc.vpnnodeselector.selection-request");
static __weak id gVPNController;
static NSUInteger gRetryGeneration;
static BOOL gApplyingRequest;

static void (*origChangeActiveVPN)(id, SEL, id);
static void (*origViewWillAppear)(id, SEL, BOOL);
static void (*origViewDidAppear)(id, SEL, BOOL);
static void (*origUpdateVPNConfigurationsList)(id, SEL);
static id (*origSpecifiersWithSpecifier)(id, SEL, id);

static id VPNSharedCopy(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VPNSharedDomain);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)VPNSharedDomain));
}

static void VPNSharedSet(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)VPNSharedDomain);
}

static NSString *VPNFriendlySpecifierName(id specifier) {
    if (!specifier) return nil;
    @try {
        for (NSString *selectorName in @[@"name", @"title"]) {
            SEL selector = NSSelectorFromString(selectorName);
            if (![specifier respondsToSelector:selector]) continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(specifier, selector);
            if ([value isKindOfClass:NSString.class] && [value length] && ![value hasPrefix:@"com.apple."]) return value;
        }
        SEL propertySelector = NSSelectorFromString(@"propertyForKey:");
        if ([specifier respondsToSelector:propertySelector]) {
            for (NSString *key in @[@"label", @"name", @"title"]) {
                id value = ((id (*)(id, SEL, id))objc_msgSend)(specifier, propertySelector, key);
                if ([value isKindOfClass:NSString.class] && [value length] && ![value hasPrefix:@"com.apple."]) return value;
            }
        }
    } @catch (__unused NSException *exception) {}
    return nil;
}

static NSString *VPNStringifyIdentifier(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value respondsToSelector:@selector(UUIDString)]) return [value UUIDString];
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return nil;
}

static NSString *VPNSpecifierIdentifier(id specifier) {
    if (!specifier) return nil;
    @try {
        for (NSString *selectorName in @[@"identifier", @"serviceID"]) {
            SEL selector = NSSelectorFromString(selectorName);
            if ([specifier respondsToSelector:selector]) {
                NSString *value = VPNStringifyIdentifier(((id (*)(id, SEL))objc_msgSend)(specifier, selector));
                if (value.length) return value;
            }
        }
        SEL propertySelector = NSSelectorFromString(@"propertyForKey:");
        if ([specifier respondsToSelector:propertySelector]) {
            for (NSString *key in @[@"identifier", @"id", @"serviceID", @"vpn-id", @"VPNServiceID"]) {
                NSString *value = VPNStringifyIdentifier(((id (*)(id, SEL, id))objc_msgSend)(specifier, propertySelector, key));
                if (value.length) return value;
            }
        }
    } @catch (__unused NSException *exception) {}
    return nil;
}

static NSArray *VPNPersonalSpecifiers(id controller) {
    SEL selector = NSSelectorFromString(@"currentPersonalVPNSpecifiers");
    if (![controller respondsToSelector:selector]) return nil;
    @try {
        id value = ((id (*)(id, SEL))objc_msgSend)(controller, selector);
        return [value isKindOfClass:NSArray.class] ? value : nil;
    } @catch (__unused NSException *exception) { return nil; }
}

static void VPNPublishSelection(NSString *name, BOOL acknowledge) {
    if (!name.length) return;
    VPNSharedSet(VPNSelectedNameKey, name);
    if (acknowledge) {
        NSString *nonce = VPNSharedCopy(VPNRequestNonceKey);
        if (nonce.length) VPNSharedSet(VPNAckNonceKey, nonce);
        VPNSharedSet(VPNRequestedNameKey, nil);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)VPNSharedDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), VPNSelectionChangedNotification, NULL, NULL, true);
}

static BOOL VPNConsumePendingRequest(id controller) {
    if (!controller || gApplyingRequest) return NO;
    NSString *requested = VPNSharedCopy(VPNRequestedNameKey);
    NSString *requestedID = VPNSharedCopy(VPNRequestedIdentifierKey);
    if (!requested.length && !requestedID.length) return YES;
    NSArray *specifiers = VPNPersonalSpecifiers(controller);
    if (specifiers.count == 0) return NO;
    for (id specifier in specifiers) {
        NSString *candidate = VPNFriendlySpecifierName(specifier);
        NSString *candidateID = VPNSpecifierIdentifier(specifier);
        BOOL identifierMatch = requestedID.length && candidateID.length && [candidateID caseInsensitiveCompare:requestedID] == NSOrderedSame;
        BOOL nameMatch = requested.length && [candidate isEqualToString:requested];
        if (!identifierMatch && !nameMatch) continue;
        SEL selector = NSSelectorFromString(@"changeActiveVPN:");
        if (![controller respondsToSelector:selector]) return NO;
        gApplyingRequest = YES;
        ((void (*)(id, SEL, id))objc_msgSend)(controller, selector, specifier);
        gApplyingRequest = NO;
        VPNPublishSelection(candidate.length ? candidate : requested, YES);
        return YES;
    }
    return NO;
}

static void VPNScheduleConsume(id controller) {
    if (controller) gVPNController = controller;
    NSUInteger generation = ++gRetryGeneration;
    for (NSNumber *delay in @[@0.0, @0.15, @0.4, @0.8, @1.5, @2.5]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != gRetryGeneration) return;
            id current = gVPNController;
            if (VPNConsumePendingRequest(current)) ++gRetryGeneration;
        });
    }
}

static void replacedChangeActiveVPN(id self, SEL _cmd, id specifier) {
    gVPNController = self;
    origChangeActiveVPN(self, _cmd, specifier);
    NSString *name = VPNFriendlySpecifierName(specifier);
    if (name.length) VPNPublishSelection(name, gApplyingRequest);
}

static void replacedViewWillAppear(id self, SEL _cmd, BOOL animated) {
    gVPNController = self;
    origViewWillAppear(self, _cmd, animated);
    VPNScheduleConsume(self);
}

static void replacedViewDidAppear(id self, SEL _cmd, BOOL animated) {
    gVPNController = self;
    origViewDidAppear(self, _cmd, animated);
    VPNScheduleConsume(self);
}

static void replacedUpdateVPNConfigurationsList(id self, SEL _cmd) {
    gVPNController = self;
    origUpdateVPNConfigurationsList(self, _cmd);
    VPNScheduleConsume(self);
}

static id replacedSpecifiersWithSpecifier(id self, SEL _cmd, id specifier) {
    gVPNController = self;
    id value = origSpecifiersWithSpecifier(self, _cmd, specifier);
    VPNScheduleConsume(self);
    return value;
}

static void VPNHandleSelectionRequest(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ VPNScheduleConsume(gVPNController); });
}

static void VPNInstallHooks(void) {
    static dispatch_once_t onceToken;
    Class cls = objc_getClass("VPNController");
    if (!cls) return;
    dispatch_once(&onceToken, ^{
        MSHookMessageEx(cls, NSSelectorFromString(@"changeActiveVPN:"), (IMP)replacedChangeActiveVPN, (IMP *)&origChangeActiveVPN);
        MSHookMessageEx(cls, @selector(viewWillAppear:), (IMP)replacedViewWillAppear, (IMP *)&origViewWillAppear);
        MSHookMessageEx(cls, @selector(viewDidAppear:), (IMP)replacedViewDidAppear, (IMP *)&origViewDidAppear);
        SEL update = NSSelectorFromString(@"updateVPNConfigurationsList");
        if ([cls instancesRespondToSelector:update]) MSHookMessageEx(cls, update, (IMP)replacedUpdateVPNConfigurationsList, (IMP *)&origUpdateVPNConfigurationsList);
        SEL specifiers = NSSelectorFromString(@"specifiersWithSpecifier:");
        if ([cls instancesRespondToSelector:specifiers]) MSHookMessageEx(cls, specifiers, (IMP)replacedSpecifiersWithSpecifier, (IMP *)&origSpecifiersWithSpecifier);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VPNHandleSelectionRequest, VPNSelectionRequestNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

static void VPNBundleLoaded(NSNotification *notification) { VPNInstallHooks(); }

__attribute__((constructor)) static void VPNControllerHookInit(void) {
    @autoreleasepool {
        dlopen("/System/Library/PreferenceBundles/VPNPreferences.bundle/VPNPreferences", RTLD_LAZY | RTLD_LOCAL);
        VPNInstallHooks();
        [NSNotificationCenter.defaultCenter addObserverForName:NSBundleDidLoadNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { VPNBundleLoaded(note); }];
    }
}
