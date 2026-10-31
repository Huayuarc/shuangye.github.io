#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <notify.h>
#include <dlfcn.h>
#include <ptrauth.h>
#include <atomic>
#include <cstring>
#import "../Shared/H120Preferences.h"
#include "H120Policy.h"
#include "H120Runtime.h"
#include "H120Recording.h"

extern "C" {
alignas(4) uint32_t H120ActiveFPSBits = 0;
void *H120OriginalRangeTimingsBB = nullptr;
void *H120OriginalRangeTimingsB = nullptr;
void *H120OriginalRangeConvert = nullptr;
void *H120OriginalRangeSource = nullptr;
void *H120OriginalRangeItemLocked = nullptr;
void *H120OriginalRangeItem = nullptr;
void H120RangeTimingsBB(void);
void H120RangeTimingsB(void);
void H120RangeConvert(void);
void H120RangeSource(void);
void H120RangeItemLocked(void);
void H120RangeItem(void);
}

static const char *const H120PolicyNotification = "cn.zqbb.hello.120hz.policy";
static std::atomic<bool> featureEnabled(false);
static std::atomic<uint32_t> configuredFPS(120);
static std::atomic<uint32_t> backboardPolicy(0);
static bool isSpringBoard = false;
static bool isBackboard = false;
static int policyToken = NOTIFY_TOKEN_INVALID;
static dispatch_source_t policyTimer;
static bool (*originalArbitration)(void);
static bool (*originalRestriction)(void);
static uint32_t (*originalPreferredDuration)(void *);
static uint32_t (*hardwareMinimumDuration)(void *);

static dispatch_queue_t H120PolicyQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.huayuarc.cputhermal.h120-policy", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

uint32_t H120ConfiguredFPS(void) { return configuredFPS.load(std::memory_order_relaxed); }
bool H120FeatureEnabled(void) { return featureEnabled.load(std::memory_order_relaxed); }

static void *H120Symbol(const char *name) {
    static MSImageRef image = MSGetImageByName("/System/Library/Frameworks/QuartzCore.framework/QuartzCore");
    return image ? MSFindSymbol(image, name) : nullptr;
}

static bool H120Install(const char *name, void *replacement, void **original) {
    void *symbol = H120Symbol(name);
    if (!symbol) return false;
    MSHookFunction(symbol, replacement, original);
    return *original != nullptr;
}

static void H120InstallRange(const char *name, void (*replacement)(void), void **slot) {
    H120Install(name, (void *)replacement, slot);
}

static bool H120Arbitration(void) {
    return H120FeatureEnabled() ? true : originalArbitration();
}

static bool H120Restriction(void) {
    return H120FeatureEnabled() ? false : originalRestriction();
}

static uint32_t H120PreferredDuration(void *display) {
    uint32_t original = originalPreferredDuration(display);
    if (!H120FeatureEnabled()) return original;
    uint32_t policy = backboardPolicy.load(std::memory_order_relaxed);
    if (!policy || !hardwareMinimumDuration || original <= 1) return original;
    return H120ChooseCadence(original, policy, hardwareMinimumDuration(display));
}

static bool H120CurrentProcessExcluded(NSDictionary *preferences) {
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    id excluded = preferences[@"selectedApps"];
    if (!identifier) return false;
    return [excluded isKindOfClass:NSArray.class] && [excluded containsObject:identifier];
}

static void H120ReadPolicy(void) {
    uint64_t state = 0;
    if (policyToken != NOTIFY_TOKEN_INVALID && notify_get_state(policyToken, &state) == NOTIFY_STATUS_OK) {

        switch (state) {
            case 0: case 2: case 3: case 4: case 8: case 24:
                backboardPolicy.store((uint32_t)state, std::memory_order_relaxed);
                return;
            default: break;
        }
    }
    backboardPolicy.store(0, std::memory_order_relaxed);
}

static void H120PublishPolicy(void) {
    if (!isSpringBoard || policyToken == NOTIFY_TOKEN_INVALID) return;
    NSProcessInfo *info = NSProcessInfo.processInfo;
    uint64_t desired = H120SystemAllowsOverride(H120FeatureEnabled(), info.lowPowerModeEnabled,
                                               (int)info.thermalState)
        ? H120CadenceForFPS((float)H120ConfiguredFPS()) : 0;
    uint64_t current = 0;
    if (notify_get_state(policyToken, &current) != NOTIFY_STATUS_OK || current != desired) {
        if (notify_set_state(policyToken, desired) == NOTIFY_STATUS_OK) notify_post(H120PolicyNotification);
    }
}

static void H120ReloadPreferences(void) {
    NSDictionary *preferences = H120ReadPreferences();
    id rate = preferences[@"wantsFPS"];
    float fps = [rate respondsToSelector:@selector(floatValue)] ? [rate floatValue] : 120.0f;
    fps = H120NormalizeFPS(fps);
    configuredFPS.store((uint32_t)fps, std::memory_order_relaxed);
    bool enabled = [preferences[@"wantsEnable"] boolValue] && !H120CurrentProcessExcluded(preferences);
    featureEnabled.store(enabled, std::memory_order_relaxed);
    uint32_t bits = 0;
    if (enabled) std::memcpy(&bits, &fps, sizeof(bits));
    __atomic_store_n(&H120ActiveFPSBits, bits, __ATOMIC_RELEASE);
    H120PublishPolicy();
    if (isBackboard) H120ReadPolicy();
}

static void H120DistributedPreferences(CFNotificationCenterRef center, void *observer,
    CFNotificationName name, const void *object, CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)object; (void)info;
    dispatch_async(H120PolicyQueue(), ^{ H120ReloadPreferences(); });
}

static void H120InstallClientHooks(void) {
    H120InstallRange("__ZN2CA7Display21DisplayTimingsControl33fps_range_to_frame_interval_rangeE16CAFrameRateRangebb",
                     H120RangeTimingsBB, &H120OriginalRangeTimingsBB);
    H120InstallRange("__ZN2CA7Display21DisplayTimingsControl33fps_range_to_frame_interval_rangeE16CAFrameRateRangeb",
                     H120RangeTimingsB, &H120OriginalRangeTimingsB);
    H120InstallRange("__Z36CAFrameRateRangeToFrameIntervalRange16CAFrameRateRangedhbbb",
                     H120RangeConvert, &H120OriginalRangeConvert);
    H120InstallRange("__ZN2CA22DynamicFrameRateSource23set_preferred_fps_rangeE16CAFrameRateRangeb",
                     H120RangeSource, &H120OriginalRangeSource);
    H120InstallRange("__ZN2CA7Display15DisplayLinkItem30set_preferred_fps_range_lockedE16CAFrameRateRangeb",
                     H120RangeItemLocked, &H120OriginalRangeItemLocked);
    H120InstallRange("__ZN2CA7Display15DisplayLinkItem23set_preferred_fps_rangeE16CAFrameRateRangebb",
                     H120RangeItem, &H120OriginalRangeItem);
    H120Install("__Z35CADisplayEnableFrameRateArbitrationv", (void *)H120Arbitration, (void **)&originalArbitration);
    H120Install("__Z39CADisplayEnableHighFrameRateRestrictionv", (void *)H120Restriction, (void **)&originalRestriction);
}

static void H120InstallBackboardHooks(void) {
    const char *preferredInternal = "__ZNK2CA12WindowServer20AppleInternalDisplay24preferred_frame_durationEv";
    const char *preferredCLCD = "__ZNK2CA12WindowServer16AppleCLCDDisplay24preferred_frame_durationEv";
    void *minimum = H120Symbol("__ZNK2CA12WindowServer16AppleCLCDDisplay31hardware_minimum_frame_durationEv");
    if (minimum) {
        minimum = ptrauth_sign_unauthenticated(ptrauth_strip(minimum, ptrauth_key_function_pointer),
                                               ptrauth_key_function_pointer, 0);
        hardwareMinimumDuration = (uint32_t (*)(void *))minimum;
    }

    if (hardwareMinimumDuration) {
        if (!H120Install(preferredInternal, (void *)H120PreferredDuration, (void **)&originalPreferredDuration))
            H120Install(preferredCLCD, (void *)H120PreferredDuration, (void **)&originalPreferredDuration);
    }
}

__attribute__((constructor)) static void H120Initialize(void) {
    @autoreleasepool {
        NSString *process = NSProcessInfo.processInfo.processName;
        isSpringBoard = [process isEqualToString:@"SpringBoard"];
        isBackboard = [process isEqualToString:@"backboardd"];
        if (isSpringBoard || isBackboard) {
            notify_register_check(H120PolicyNotification, &policyToken);
        }
        if (isBackboard) {
            H120InstallBackboardHooks();
            static int dispatchToken;
            notify_register_dispatch(H120PolicyNotification, &dispatchToken, dispatch_get_main_queue(), ^(int token) {
                (void)token; H120ReadPolicy();
            });
        } else if ([process isEqualToString:@"replayd"]) {
            H120InstallRecordingHooks();
        } else {
            H120InstallClientHooks();
        }
        static int preferencesToken;
        notify_register_dispatch(H120PreferencesNotification.UTF8String, &preferencesToken,
                                 H120PolicyQueue(), ^(int token) {
            (void)token; H120ReloadPreferences();
        });
        CFNotificationCenterRef center = H120DistributedNotificationCenter();
        if (center) CFNotificationCenterAddObserver(center, NULL, H120DistributedPreferences,
            (__bridge CFStringRef)H120PreferencesNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_async(H120PolicyQueue(), ^{
            H120ReloadPreferences();
            if (isSpringBoard) {

                // 策略发布不操作 UI，放到 Utility 队列，避免每秒占用 SpringBoard 主线程。
                policyTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, H120PolicyQueue());
                dispatch_source_set_timer(policyTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                          NSEC_PER_SEC, NSEC_PER_SEC / 10);
                dispatch_source_set_event_handler(policyTimer, ^{ H120PublishPolicy(); });
                dispatch_resume(policyTimer);
            }
        });
    }
}
