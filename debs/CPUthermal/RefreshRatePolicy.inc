// Included only by RefreshRate.xm: one Objective-C++ translation unit.
// Reference arm64: policy replacements 0x4da0/0x4da8/0x4db0/0x4dc0,
// controller setter 0x4dd0, dynamic range replacement 0x7e00 (s0/s1/s2).
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <notify.h>
#include <string.h>
#include <stdlib.h>

static id gAppRateSource;
static BOOL CPUthermalInteractionHold(void);
static void CPUthermalUILifecycle(void);
static void CPUthermalRefreshAnimations(void);
static void CPUthermalOwnedSourceReason(id source);
static id gSBRateSource;
static BOOL gSBSourceWrite;
static BOOL gSBOwnedRangeWritten;
static CAFrameRateRange gSBSourceNativeRange;
static int gRateLockToken = -1, gRateBlankToken = -1;
static NSMutableSet<NSString *> *gRateInstalled;
static NSMutableSet<NSString *> *gRateDiagnosed;
static NSMutableSet<NSString *> *gRateChecked; // result cache incl. ABI misses; late classes retried when loaded

static void CPUthermalRateDiagnostic(NSString *message) {
    // Main-thread event diagnostics only; never a display-link callback or file IO.
    if (!gRateLogging) return;
    if (!gRateDiagnosed) gRateDiagnosed = [NSMutableSet new];
    if ([gRateDiagnosed containsObject:message]) return;
    [gRateDiagnosed addObject:message];
    NSLog(@"[CPUthermal refresh] %@", message);
}
static BOOL CPUthermalExactMethod(Method method, const char *result, NSArray<NSString *> *arguments) {
    if (!method || !method_getTypeEncoding(method) || method_getNumberOfArguments(method) != arguments.count) return NO;
    // Compare EVERY runtime type including self/_cmd; offsets are layout metadata.
    // No stripping qualifiers, coercing pointers/objects, or float/double guessing.
    char *type = method_copyReturnType(method);
    BOOL valid = type && strcmp(type, result) == 0;
    free(type);
    for (unsigned int i = 0; valid && i < arguments.count; ++i) {
        type = method_copyArgumentType(method, i);
        valid = type && strcmp(type, arguments[i].UTF8String) == 0;
        free(type);
    }
    return valid;
}
static BOOL CPUthermalSystemRateActive(void) {
    return NSThread.isMainThread && gIsSpringBoard && gScreenReady
        && gForce120Hz && CPUthermalDeviceSupports120Hz();
}
static BOOL CPUthermalSourceRateActive(void) {
    return NSThread.isMainThread && gScreenReady
        && (gIsSpringBoard ? CPUthermalSystemRateActive() : (gScreenUnlocked && CPUthermalShouldForce120Hz()));
}
static Class CPUthermalMethodOwner(Class target, SEL selector) {
    // Resolve actual declaring owner: parent/child inherited method is hooked once.
    for (Class cls = target; cls; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        BOOL found = NO;
        for (unsigned int i = 0; i < count; ++i) {
            if (method_getName(methods[i]) == selector) { found = YES; break; }
        }
        free(methods);
        if (found) return cls;
    }
    return Nil;
}
static NSString *CPUthermalHookKey(Class owner, SEL selector) {
    return [NSString stringWithFormat:@"%p/%@", (__bridge void *)owner, NSStringFromSelector(selector)];
}
static BOOL CPUthermalRateAlreadyChecked(Class cls, SEL selector) {
    if (!cls) return NO; // late-loaded classes must be retried
    if (!gRateChecked) gRateChecked = [NSMutableSet new];
    NSString *key = CPUthermalHookKey(cls, selector);
    if ([gRateChecked containsObject:key]) return YES;
    [gRateChecked addObject:key];
    return NO;
}
static BOOL CPUthermalClaimHook(Class owner, SEL selector) {
    if (!owner) return NO;
    if (!gRateInstalled) gRateInstalled = [NSMutableSet new];
    NSString *key = CPUthermalHookKey(owner, selector);
    if ([gRateInstalled containsObject:key]) return NO;
    [gRateInstalled addObject:key];
    return YES;
}
static void CPUthermalHookSkip(Class target, SEL selector, Method method) {
    const char *encoding = method ? method_getTypeEncoding(method) : "missing";
    CPUthermalRateDiagnostic([NSString stringWithFormat:@"skip %@.%@: %s", NSStringFromClass(target), NSStringFromSelector(selector), encoding ?: "null"]);
}

@interface CPUthermalPrivateRateState : NSObject
@property(nonatomic) CAFrameRateRange range;
@property(nonatomic) BOOL hasRange;
@property(nonatomic) long long integer;
@property(nonatomic) BOOL hasInteger;
@property(nonatomic) BOOL forced;
@property(nonatomic) NSUInteger depth;
@property(nonatomic) IMP original;
@property(nonatomic) SEL selector;
// Encoding is immutable per runtime method. Function pointer ABI retained below.
@property(nonatomic, copy) NSString *type;
@end
@implementation CPUthermalPrivateRateState
@end
static NSMapTable<id, CPUthermalPrivateRateState *> *gPrivateRanges, *gPrivateControllers;
static CPUthermalPrivateRateState *CPUthermalPrivateState(NSMapTable<id, CPUthermalPrivateRateState *> *__strong *map, id object) {
    if (!NSThread.isMainThread || !object) return nil;
    if (!*map) *map = [NSMapTable weakToStrongObjectsMapTable];
    CPUthermalPrivateRateState *state = [*map objectForKey:object];
    if (!state) { state = [CPUthermalPrivateRateState new]; [*map setObject:state forKey:object]; }
    return state;
}
// No capability hook. Validate object ABIs before accessing a source's display.
static BOOL CPUthermalSourceIsMainDisplay(id source) {
    if (source == gSBRateSource) return YES; // bound by verified initWithDisplay:
    return source == gAppRateSource || CPUthermalInteractionHold();
}
static void CPUthermalApplyPrivateRange(id object, CPUthermalPrivateRateState *state, BOOL active) {
    if (!state.hasRange || state.depth || !state.original) return;
    BOOL force = active && CPUthermalSourceIsMainDisplay(object);
    if (!force && !state.forced) return;
    ++state.depth;
    CAFrameRateRange range = force ? CAFrameRateRangeMake(120, 120, 120) : state.range;
    @try {
        ((void (*)(id, SEL, CAFrameRateRange))state.original)(object, state.selector, range);
        state.forced = force;
    } @finally { --state.depth; }
}
template<typename T> static void CPUthermalApplyPrivateInteger(id object, CPUthermalPrivateRateState *state, BOOL active) {
    if (!state.hasInteger || state.depth || !state.original || (!active && !state.forced)) return;
    ++state.depth;
    @try {
        ((void (*)(id, SEL, T))state.original)(object, state.selector, active ? (T)120 : (T)state.integer);
        state.forced = active;
    } @finally { --state.depth; }
}
template<typename T> static BOOL CPUthermalInstallIntegerGetter(Class target, SEL selector, const char *type, BOOL limit) {
    Method method = class_getInstanceMethod(target, selector);
    if (!CPUthermalExactMethod(method, type, @[@"@", @":"])) return NO;
    Class owner = CPUthermalMethodOwner(target, selector);
    if (!CPUthermalClaimHook(owner, selector)) return YES;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^T(id object) {
        // Off-main uses only immutable original/selector, never the main-thread model.
        T value = ((T (*)(id, SEL))original)(object, selector);
        if (!NSThread.isMainThread || ![object isKindOfClass:target] || !CPUthermalSystemRateActive()) return value;
        return limit ? (T)0 : (T)120;
    });
    MSHookMessageEx(owner, selector, replacement, &original);
    CPUthermalRateDiagnostic([NSString stringWithFormat:@"installed %@.%s %s", NSStringFromClass(owner), sel_getName(selector), type]);
    return YES;
}
template<typename T> static BOOL CPUthermalInstallIntegerSetter(Class target, SEL selector, const char *type) {
    Method method = class_getInstanceMethod(target, selector);
    if (!CPUthermalExactMethod(method, "v", @[@"@", @":", [NSString stringWithUTF8String:type]])) return NO;
    Class owner = CPUthermalMethodOwner(target, selector);
    if (!CPUthermalClaimHook(owner, selector)) return YES;
    __block IMP original = NULL;
    NSString *savedType = [NSString stringWithUTF8String:type];
    IMP replacement = imp_implementationWithBlock(^(id object, T value) {
        if (!NSThread.isMainThread || ![object isKindOfClass:target]) { ((void (*)(id, SEL, T))original)(object, selector, value); return; }
        CPUthermalPrivateRateState *state = CPUthermalPrivateState(&gPrivateControllers, object);
        if (state.depth) { ((void (*)(id, SEL, T))original)(object, selector, value); return; }
        state.integer = (long long)value; state.hasInteger = YES;
        state.original = original; state.selector = selector; state.type = savedType;
        ++state.depth;
        @try { ((void (*)(id, SEL, T))original)(object, selector, value); }
        @finally { --state.depth; }
        CPUthermalApplyPrivateInteger<T>(object, state, CPUthermalSystemRateActive());
    });
    MSHookMessageEx(owner, selector, replacement, &original);
    CPUthermalRateDiagnostic([NSString stringWithFormat:@"installed reversible %@.%s %s", NSStringFromClass(owner), sel_getName(selector), type]);
    return YES;
}
static void CPUthermalInstallPrivateRateHooks(void) {
    if (!NSThread.isMainThread) return;
    if (gIsSpringBoard) {
        // Reference maximum/active getters are NOT copied: they may masquerade
        // as capability/observed rate. Only policy inputs/default are overridden.
        for (NSString *className in @[@"SBProMotionPolicy", @"SBDisplayRefreshRateController"]) {
            Class cls = NSClassFromString(className);
            if (!cls) { CPUthermalRateDiagnostic([@"missing class " stringByAppendingString:className]); continue; }
            NSArray<NSString *> *selectors = [className isEqualToString:@"SBProMotionPolicy"]
                ? @[@"policyRefreshRate", @"isLimitFrameRateEnabled", @"shouldLimitFrameRate"] : @[@"defaultRefreshRate"];
            for (NSString *name in selectors) {
                SEL sel = NSSelectorFromString(name);
                BOOL limit = [name isEqualToString:@"isLimitFrameRateEnabled"] || [name isEqualToString:@"shouldLimitFrameRate"];
                if (CPUthermalRateAlreadyChecked(cls, sel)) continue;
                BOOL installed = limit
                    ? (CPUthermalInstallIntegerGetter<BOOL>(cls, sel, @encode(BOOL), YES) || CPUthermalInstallIntegerGetter<signed char>(cls, sel, "c", YES))
                    : (CPUthermalInstallIntegerGetter<int>(cls, sel, "i", NO) || CPUthermalInstallIntegerGetter<unsigned int>(cls, sel, "I", NO) ||
                       CPUthermalInstallIntegerGetter<long long>(cls, sel, "q", NO) || CPUthermalInstallIntegerGetter<unsigned long long>(cls, sel, "Q", NO));
                if (!installed) CPUthermalHookSkip(cls, sel, class_getInstanceMethod(cls, sel));
            }
            if ([className isEqualToString:@"SBDisplayRefreshRateController"]) {
                SEL sel = NSSelectorFromString(@"setActiveRefreshRate:");
                if (CPUthermalRateAlreadyChecked(cls, sel)) continue;
                BOOL installed = CPUthermalInstallIntegerSetter<int>(cls, sel, "i") || CPUthermalInstallIntegerSetter<unsigned int>(cls, sel, "I") ||
                    CPUthermalInstallIntegerSetter<long long>(cls, sel, "q") || CPUthermalInstallIntegerSetter<unsigned long long>(cls, sel, "Q");
                if (!installed) CPUthermalHookSkip(cls, sel, class_getInstanceMethod(cls, sel));
            }
        }
    }
    // s0/s1/s2 verified in reference; ONLY the SDK's three-float struct ABI.
    // Double structs, CF pointers, reason enums, initWithDisplay are not hooked.
    Class cls = NSClassFromString(@"CADynamicFrameRateSource");
    SEL selector = NSSelectorFromString(@"setPreferredFrameRateRange:");
    if (CPUthermalRateAlreadyChecked(cls, selector)) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!CPUthermalExactMethod(method, "v", @[@"@", @":", [NSString stringWithUTF8String:@encode(CAFrameRateRange)]])) {
        CPUthermalHookSkip(cls, selector, method); return;
    }
    Class owner = CPUthermalMethodOwner(cls, selector);
    if (!CPUthermalClaimHook(owner, selector)) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object, CAFrameRateRange range) {
        if (!NSThread.isMainThread || gSBSourceWrite || (!CPUthermalSourceIsMainDisplay(object) && ![gPrivateRanges objectForKey:object]) || ![object isKindOfClass:cls]) { ((void (*)(id, SEL, CAFrameRateRange))original)(object, selector, range); return; }
        CPUthermalPrivateRateState *state = CPUthermalPrivateState(&gPrivateRanges, object);
        if (state.depth) { ((void (*)(id, SEL, CAFrameRateRange))original)(object, selector, range); return; }
        state.range = range; state.hasRange = YES; state.original = original; state.selector = selector;
        ++state.depth;
        @try { ((void (*)(id, SEL, CAFrameRateRange))original)(object, selector, range); }
        @finally { --state.depth; }
        CPUthermalApplyPrivateRange(object, state, CPUthermalSourceRateActive());
    });
    MSHookMessageEx(owner, selector, replacement, &original);
    CPUthermalRateDiagnostic(@"installed CADynamicFrameRateSource three-float range request");
}
static void CPUthermalRefreshPrivateRequests(void) {
    BOOL active = CPUthermalSystemRateActive();
    for (id object in gPrivateControllers.keyEnumerator.allObjects) {
        CPUthermalPrivateRateState *state = [gPrivateControllers objectForKey:object];
        if ([state.type isEqualToString:@"i"]) CPUthermalApplyPrivateInteger<int>(object, state, active);
        else if ([state.type isEqualToString:@"I"]) CPUthermalApplyPrivateInteger<unsigned int>(object, state, active);
        else if ([state.type isEqualToString:@"q"]) CPUthermalApplyPrivateInteger<long long>(object, state, active);
        else if ([state.type isEqualToString:@"Q"]) CPUthermalApplyPrivateInteger<unsigned long long>(object, state, active);
    }
    for (id object in gPrivateRanges.keyEnumerator.allObjects)
        CPUthermalApplyPrivateRange(object, [gPrivateRanges objectForKey:object], CPUthermalSourceRateActive());
}
@interface CPUthermalSBRateTarget : NSObject
- (void)rateTick:(CADisplayLink *)link;
@end
@implementation CPUthermalSBRateTarget
- (void)rateTick:(__unused CADisplayLink *)link {
    // Intentionally empty: scheduler request only. NO prefs, NSLog, windows,
    // layers, runtime discovery, IO or private reason reassertion per frame.
}
@end
static CADisplayLink *gSBRateLink;
static CPUthermalSBRateTarget *gSBRateTarget;
@interface CPUthermalDynamicRateSource : NSObject
- (instancetype)initWithDisplay:(id)display;
@end

static void CPUthermalUpdateSBSource(void);
#include "RefreshRateUIState.inc"

static void CPUthermalUpdateSBSource(void) {
    Class cls = NSClassFromString(@"CADynamicFrameRateSource");
    SEL setter = NSSelectorFromString(@"setPreferredFrameRateRange:");
    if (!CPUthermalSystemRateActive()) {
        if (gSBRateSource) {
            Method method = class_getInstanceMethod(object_getClass(gSBRateSource), setter);
            if (CPUthermalExactMethod(method, "v", @[@"@", @":", [NSString stringWithUTF8String:@encode(CAFrameRateRange)]])) {
                gSBSourceWrite = YES;
                @try { ((void (*)(id, SEL, CAFrameRateRange))method_getImplementation(method))(gSBRateSource, setter, gSBSourceNativeRange); }
                @finally { gSBSourceWrite = NO; }
            }
            [gPrivateRanges removeObjectForKey:gSBRateSource];
            gSBRateSource = nil;
            gSBOwnedRangeWritten = NO;
            CPUthermalRateDiagnostic(@"SpringBoard source restored to captured native range and released");
        }
        return;
    }
    if (!gSBRateSource) {
        Class displayClass = NSClassFromString(@"CADisplay");
        SEL mainSelector = NSSelectorFromString(@"mainDisplay");
        SEL initializer = NSSelectorFromString(@"initWithDisplay:");
        SEL getter = NSSelectorFromString(@"preferredFrameRateRange");
        Method mainMethod = class_getClassMethod(displayClass, mainSelector);
        Method initMethod = class_getInstanceMethod(cls, initializer);
        Method getterMethod = class_getInstanceMethod(cls, getter);
        Method setterMethod = class_getInstanceMethod(cls, setter);
        // The sample confirms initWithDisplay: and float range requests. The
        // native getter is an additional runtime requirement for safe release.
        if (!CPUthermalExactMethod(mainMethod, "@", @[@"@", @":"]) ||
            !CPUthermalExactMethod(initMethod, "@", @[@"@", @":", @"@"]) ||
            !CPUthermalExactMethod(getterMethod, @encode(CAFrameRateRange), @[@"@", @":"]) ||
            !CPUthermalExactMethod(setterMethod, "v", @[@"@", @":", [NSString stringWithUTF8String:@encode(CAFrameRateRange)]])) {
            CPUthermalRateDiagnostic(@"SpringBoard source creation skipped: full init/getter/setter ABI unavailable"); return;
        }
        id display = ((id (*)(id, SEL))method_getImplementation(mainMethod))(displayClass, mainSelector);
        if (!display) return;
        // Known init-family declaration gives ARC exact ownership semantics.
        // Construction setters must NOT be forced before the native snapshot.
        gSBSourceWrite = YES;
        @try { gSBRateSource = [(CPUthermalDynamicRateSource *)[cls alloc] initWithDisplay:display]; }
        @catch (__unused NSException *error) { gSBRateSource = nil; CPUthermalRateDiagnostic(@"source initializer raised; skipped"); }
        @finally { gSBSourceWrite = NO; }
        if (!gSBRateSource) return;
        getterMethod = class_getInstanceMethod(object_getClass(gSBRateSource), getter);
        setterMethod = class_getInstanceMethod(object_getClass(gSBRateSource), setter);
        if (!CPUthermalExactMethod(getterMethod, @encode(CAFrameRateRange), @[@"@", @":"]) ||
            !CPUthermalExactMethod(setterMethod, "v", @[@"@", @":", [NSString stringWithUTF8String:@encode(CAFrameRateRange)]])) {
            gSBRateSource = nil; return;
        }
        gSBSourceNativeRange = ((CAFrameRateRange (*)(id, SEL))method_getImplementation(getterMethod))(gSBRateSource, getter);
        CPUthermalRateDiagnostic(@"one SpringBoard main-display source created with native range captured");
    }
    Method method = class_getInstanceMethod(object_getClass(gSBRateSource), setter);
    if (CPUthermalExactMethod(method, "v", @[@"@", @":", [NSString stringWithUTF8String:@encode(CAFrameRateRange)]]) && !gSBOwnedRangeWritten) {
        gSBSourceWrite = YES;
        @try {
            CPUthermalOwnedSourceReason(gSBRateSource);
            ((void (*)(id, SEL, CAFrameRateRange))method_getImplementation(method))(gSBRateSource, setter, CAFrameRateRangeMake(120, 120, 120));
            gSBOwnedRangeWritten = YES;
        } @finally { gSBSourceWrite = NO; }
    }
}
static void CPUthermalUpdateSBKeepAlive(void) {
    if (!CPUthermalSystemRateActive()) {
        if (gSBRateLink) {
            [gSBRateLink invalidate]; gSBRateLink = nil; gSBRateTarget = nil;
            CPUthermalRateDiagnostic(@"SpringBoard keepalive destroyed; native requests restored");
        }
        return;
    }
    if (!gSBRateLink) {
        gSBRateTarget = [CPUthermalSBRateTarget new];
        gSBRateLink = [CADisplayLink displayLinkWithTarget:gSBRateTarget selector:@selector(rateTick:)];
        gSBRateLink.preferredFrameRateRange = CAFrameRateRangeMake(120, 120, 120);
        [gSBRateLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        CPUthermalRateDiagnostic(@"one unlocked/visible main-screen SpringBoard keepalive created");
    }
}
static void CPUthermalReadScreenState(void) {
    uint64_t locked = 1, blanked = 1;
    // Unknown signals fail closed. Lock screen deliberately excluded.
    gScreenReady = gRateBlankToken >= 0 && notify_get_state(gRateBlankToken, &blanked) == NOTIFY_STATUS_OK && blanked == 0;
    gScreenUnlocked = gRateLockToken >= 0 && notify_get_state(gRateLockToken, &locked) == NOTIFY_STATUS_OK && locked == 0;
}
static void CPUthermalRateLifecycle(void) {
    CPUthermalReadScreenState();
    CPUthermalUILifecycle();
    CPUthermalRefreshAnimations();
    CPUthermalRefreshTracked(YES);
    CPUthermalRefreshPrivateRequests();
    CPUthermalUpdateSBSource();
    CPUthermalUpdateSBKeepAlive();
}
static BOOL gRateLifecycleQueued;
static void CPUthermalQueueRateLifecycle(void) {
    if (gRateLifecycleQueued) return;
    gRateLifecycleQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gRateLifecycleQueued = NO;
        CPUthermalRateLifecycle();
    });
}
static void CPUthermalSetupRateLifecycle(void) {
    gIsSpringBoard = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
    notify_register_dispatch("com.apple.springboard.lockstate", &gRateLockToken, dispatch_get_main_queue(), ^(__unused int token) {
        CPUthermalQueueRateLifecycle();
    });
    notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &gRateBlankToken, dispatch_get_main_queue(), ^(__unused int token) {
        CPUthermalQueueRateLifecycle();
    });
    CPUthermalReadScreenState();
    CPUthermalInstallPrivateRateHooks();
}
