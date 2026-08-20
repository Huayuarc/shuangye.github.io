#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>

static NSString *const VPNSharedDomain = @"com.huayuarc.vpnnodeselector.shared";
static NSString *const VPNSelectedNameKey = @"SelectedName";
static NSString *const VPNRequestedNameKey = @"RequestedName";
static CFStringRef const VPNSelectionChangedNotification = CFSTR("com.huayuarc.vpnnodeselector.selection-changed");
static CFStringRef const VPNSelectionRequestNotification = CFSTR("com.huayuarc.vpnnodeselector.selection-request");
static __weak id gVPNController;
static void (*origChangeActiveVPN)(id, SEL, id);
static void (*origViewDidAppear)(id, SEL, BOOL);

static NSString *VPNFriendlySpecifierName(id specifier) {
    if (!specifier) return nil;
    @try {
        for (NSString *selectorName in @[@"name", @"title"]) {
            SEL selector = NSSelectorFromString(selectorName);
            if ([specifier respondsToSelector:selector]) {
                id value = ((id (*)(id, SEL))objc_msgSend)(specifier, selector);
                if ([value isKindOfClass:NSString.class] && [value length] && ![value hasPrefix:@"com.apple."]) return value;
            }
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

static NSArray *VPNPersonalSpecifiers(id controller) {
    SEL selector = NSSelectorFromString(@"currentPersonalVPNSpecifiers");
    if (![controller respondsToSelector:selector]) return nil;
    @try {
        id value = ((id (*)(id, SEL))objc_msgSend)(controller, selector);
        return [value isKindOfClass:NSArray.class] ? value : nil;
    } @catch (__unused NSException *exception) { return nil; }
}

static void VPNPublishSelectedName(NSString *name) {
    if (!name.length) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)VPNSelectedNameKey, (__bridge CFStringRef)name, (__bridge CFStringRef)VPNSharedDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)VPNSharedDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), VPNSelectionChangedNotification, NULL, NULL, true);
}

static void replacedChangeActiveVPN(id self, SEL _cmd, id specifier) {
    gVPNController = self;
    origChangeActiveVPN(self, _cmd, specifier);
    NSString *name = VPNFriendlySpecifierName(specifier);
    if (name.length) VPNPublishSelectedName(name);
}

static void replacedViewDidAppear(id self, SEL _cmd, BOOL animated) {
    gVPNController = self;
    origViewDidAppear(self, _cmd, animated);
}

static void VPNHandleSelectionRequest(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id controller = gVPNController;
        if (!controller) return;
        CFPreferencesAppSynchronize((__bridge CFStringRef)VPNSharedDomain);
        NSString *requested = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)VPNRequestedNameKey, (__bridge CFStringRef)VPNSharedDomain));
        if (!requested.length) return;
        for (id specifier in VPNPersonalSpecifiers(controller)) {
            NSString *candidate = VPNFriendlySpecifierName(specifier);
            if (![candidate isEqualToString:requested]) continue;
            SEL selector = NSSelectorFromString(@"changeActiveVPN:");
            if ([controller respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(controller, selector, specifier);
            return;
        }
    });
}

static void VPNInstallHooks(void) {
    static dispatch_once_t onceToken;
    Class cls = objc_getClass("VPNController");
    if (!cls) return;
    dispatch_once(&onceToken, ^{
        MSHookMessageEx(cls, NSSelectorFromString(@"changeActiveVPN:"), (IMP)replacedChangeActiveVPN, (IMP *)&origChangeActiveVPN);
        MSHookMessageEx(cls, @selector(viewDidAppear:), (IMP)replacedViewDidAppear, (IMP *)&origViewDidAppear);
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
