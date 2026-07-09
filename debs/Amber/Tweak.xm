#define HBLogDebug(...) NSLog(__VA_ARGS__)

#include <substrate.h>
#import "Header.h"

#import <dlfcn.h>
#import <mach/port.h>
#import <mach/kern_return.h>
#import <dispatch/dispatch.h>

// Tweak
// 0 - white only (default)
// 1 - both
// 2 - amber only

/**
    This tweak can tell the camera to use only the amber LED for torch.
    In normal situations, the camera decides whether to turn on the amber LED if the scene temperature matches.
    Amber tricks the camera into thinking that the scene always matches amber lighting condition.
    When the scene is determined to be the warmest (percentile >= 100), only amber LED will turn on.

    However, the concept differs for iPhone 7 (H9ISP) and newer which include quad-LEDs (two white's and two amber's).
    Faking the scene condition is no longer relevant, as SetTorchLevel() calls a different function that does no longer
    rely on the scene condition, but surprisingly presents another neat solution to enabling the amber light.
    The function is SetIndividualTorchLEDLevels() that can literally be used to manipulate the brightness level of each individual LED.

    The levels are represented as a single 32-bit integer. This integer is separated into 8-bit chunks.
    From left to right, the 1st and the 3rd chunks specify the brightness level of the white LEDs (0x00 as min and 0xFF as max).
    Similarly, the 2nd and the 4th chunks specify the brightness level of the amber LEDs (0x00 as min and 0xFF as max).
    Easy enough, having only amber light requires us to set the integer level to be 0x00hh00hh.
    By default, H6ISP and H9ISP cameras ensure that the brightness format is in 0xhh00hh00, locking down any non-jailbroken attempts.
**/

typedef struct HXISPCaptureStream *HXISPCaptureStreamRef;
typedef struct HXISPCaptureDevice *HXISPCaptureDeviceRef;
typedef struct HXISPCaptureGroup *HXISPCaptureGroupRef;

int (*SetTorchLevel)(CFNumberRef, HXISPCaptureStreamRef, HXISPCaptureDeviceRef) = NULL;
int (*SetTorchLevelWithGroup)(CFNumberRef, HXISPCaptureStreamRef, HXISPCaptureGroupRef, HXISPCaptureDeviceRef) = NULL;
int (*SetTorchColor)(CFMutableDictionaryRef, HXISPCaptureStreamRef, HXISPCaptureDeviceRef) = NULL;
int (*SetTorchColorWithGroup)(CFMutableDictionaryRef, HXISPCaptureStreamRef, HXISPCaptureGroupRef, HXISPCaptureDeviceRef) = NULL;
// SetTorchColorMode is called through function pointer directly (not hooked via MSHookFunction, called explicitly)
int (*SetTorchColorMode)(void *, unsigned int, unsigned short, unsigned short) = NULL;
SInt32 (*GetCFPreferenceNumber)(CFStringRef const, CFStringRef const, SInt32) = NULL;

// Function pointers resolved from binary - these will be MSHookFunction'd
int (*SetIndividualTorchLEDLevels)(void *, unsigned int, unsigned int) = NULL;

// Original function pointers (stored by MSHookFunction before patching)
static int (*orig_SetIndividualTorchLEDLevels)(void *, unsigned int, unsigned int) = NULL;
static int (*orig_SetTorchLevel)(CFNumberRef, HXISPCaptureStreamRef, HXISPCaptureDeviceRef) = NULL;
static int (*orig_SetTorchLevelWithGroup)(CFNumberRef, HXISPCaptureStreamRef, HXISPCaptureGroupRef, HXISPCaptureDeviceRef) = NULL;
static int (*orig_SetTorchColorMode)(void *, unsigned int, unsigned short, unsigned short) = NULL;

// Strobe state
static dispatch_queue_t strobeQueue = NULL;
static bool isStrobeToggleOn = false;    // whether torch is physically on right now (timer toggle state)
static bool isStrobeRunning = false;     // whether strobe timer is active
static int strobeSavedLevel = 0;         // saved brightness level
static bool hasDualLED = false;          // flag: using dual-LED path
static bool hasQuadLED = false;          // flag: using quad-LED path

// --- Dual-LED saved context ---
static HXISPCaptureStreamRef savedStream = NULL;
static HXISPCaptureDeviceRef savedDevice = NULL;
static HXISPCaptureGroupRef savedGroup = NULL;
static bool savedHasGroup = false;

// --- Quad-LED saved context ---
static void *savedQuadArg0 = NULL;
static unsigned int savedQuadArg1 = 0;
static unsigned int savedQuadLevels = 0;

// --- SOS state machine ---
#define SOS_UNIT_NS (200 * NSEC_PER_MSEC)

static int sosCurrentStep = 0;
static int sosTotalCycles = 0;
static int sosCurrentCycle = 0;
static bool sosRunning = false;

// SOS step definitions: { on, duration_ns }
static const struct { bool on; uint64_t dur; } sosSteps[] = {
    // S = ...
    {true,  1 * SOS_UNIT_NS},   // dot on
    {false, 1 * SOS_UNIT_NS},   // intra-char gap
    {true,  1 * SOS_UNIT_NS},   // dot on
    {false, 1 * SOS_UNIT_NS},   // intra-char gap
    {true,  1 * SOS_UNIT_NS},   // dot on
    {false, 3 * SOS_UNIT_NS},   // inter-char gap
    // O = ---
    {true,  3 * SOS_UNIT_NS},   // dash on
    {false, 1 * SOS_UNIT_NS},   // intra-char gap
    {true,  3 * SOS_UNIT_NS},   // dash on
    {false, 1 * SOS_UNIT_NS},   // intra-char gap
    {true,  3 * SOS_UNIT_NS},   // dash on
    {false, 3 * SOS_UNIT_NS},   // inter-char gap
    // S = ...
    {true,  1 * SOS_UNIT_NS},   // dot on
    {false, 1 * SOS_UNIT_NS},   // intra-char gap
    {true,  1 * SOS_UNIT_NS},   // dot on
    {false, 1 * SOS_UNIT_NS},   // intra-char gap
    {true,  1 * SOS_UNIT_NS},   // dot on
    {false, 7 * SOS_UNIT_NS},   // end-of-cycle gap
};
static const int sosStepCount = sizeof(sosSteps) / sizeof(sosSteps[0]);

#pragma mark - Preference reading helpers

static SInt32 amberMode(void) {
    return GetCFPreferenceNumber ? GetCFPreferenceNumber(amberModeKey, kDomain, PSAmberModeDefault) : PSAmberModeDefault;
}

static bool strobeEnabled(void) {
    return CFPreferencesGetAppIntegerValue(strobeEnabledKey, strobeDomain, NULL) != 0;
}

static double strobeFrequency(void) {
    CFPropertyListRef val = CFPreferencesCopyAppValue(strobeFrequencyKey, strobeDomain);
    double freq = 3.0;
    if (val) {
        if (CFGetTypeID(val) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)val, kCFNumberDoubleType, &freq);
        CFRelease(val);
    }
    if (freq < 0.5) freq = 0.5;
    if (freq > 20.0) freq = 20.0;
    return freq;
}

static int strobePattern(void) {
    return (int)CFPreferencesGetAppIntegerValue(strobePatternKey, strobeDomain, NULL);
}

static int strobeSOSCycles(void) {
    int cycles = (int)CFPreferencesGetAppIntegerValue(strobeSOSCyclesKey, strobeDomain, NULL);
    if (cycles < 1) cycles = 3;
    if (cycles > 20) cycles = 20;
    return cycles;
}

#pragma mark - Physical LED control (Dual-LED)

static void strobeOnPhysical(void) {
    if (strobeSavedLevel <= 0) return;
    int level = strobeSavedLevel;
    CFNumberRef levelNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &level);
    if (savedHasGroup && orig_SetTorchLevelWithGroup)
        orig_SetTorchLevelWithGroup(levelNum, savedStream, savedGroup, savedDevice);
    else if (orig_SetTorchLevel)
        orig_SetTorchLevel(levelNum, savedStream, savedDevice);
    CFRelease(levelNum);
}

static void strobeOffPhysical(void) {
    int zero = 0;
    CFNumberRef levelNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &zero);
    if (savedHasGroup && orig_SetTorchLevelWithGroup)
        orig_SetTorchLevelWithGroup(levelNum, savedStream, savedGroup, savedDevice);
    else if (orig_SetTorchLevel)
        orig_SetTorchLevel(levelNum, savedStream, savedDevice);
    CFRelease(levelNum);
}

#pragma mark - Continuous strobe dispatch chain

static void continuousStrobeTick(void) {
    if (!isStrobeRunning) return;

    double freq = strobeFrequency();
    uint64_t halfPeriodNS = (freq > 0) ? (uint64_t)((double)NSEC_PER_SEC / freq / 2.0) : (500 * NSEC_PER_MSEC);
    if (halfPeriodNS < 5 * NSEC_PER_MSEC) halfPeriodNS = 5 * NSEC_PER_MSEC;

    if (isStrobeToggleOn) {
        // Turn off
        if (hasQuadLED)
            orig_SetIndividualTorchLEDLevels(savedQuadArg0, savedQuadArg1, 0);
        else if (hasDualLED)
            strobeOffPhysical();
        isStrobeToggleOn = false;
    } else {
        // Turn on
        if (hasQuadLED)
            orig_SetIndividualTorchLEDLevels(savedQuadArg0, savedQuadArg1, savedQuadLevels);
        else if (hasDualLED)
            strobeOnPhysical();
        isStrobeToggleOn = true;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, halfPeriodNS), strobeQueue, ^{
        continuousStrobeTick();
    });
}

#pragma mark - SOS chain

static void sosDoStep(void) {
    if (!sosRunning || !isStrobeRunning) return;

    int stepIdx = sosCurrentStep % sosStepCount;
    if (stepIdx == 0 && sosCurrentStep > 0) {
        sosCurrentCycle++;
        if (sosCurrentCycle >= sosTotalCycles) {
            // Cycles done, loop back
            sosCurrentCycle = 0;
        }
    }
    stepIdx = sosCurrentStep % sosStepCount;

    if (sosSteps[stepIdx].on) {
        if (hasQuadLED)
            orig_SetIndividualTorchLEDLevels(savedQuadArg0, savedQuadArg1, savedQuadLevels);
        else if (hasDualLED)
            strobeOnPhysical();
    } else {
        if (hasQuadLED)
            orig_SetIndividualTorchLEDLevels(savedQuadArg0, savedQuadArg1, 0);
        else if (hasDualLED)
            strobeOffPhysical();
    }

    sosCurrentStep++;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, sosSteps[stepIdx].dur), strobeQueue, ^{
        sosDoStep();
    });
}

#pragma mark - Strobe start/stop

static void startStrobe(void) {
    if (!strobeQueue) {
        strobeQueue = dispatch_queue_create("com.ps.amber.strobe", DISPATCH_QUEUE_SERIAL);
    }

    isStrobeRunning = true;
    isStrobeToggleOn = true; // start from "on" state
    sosCurrentStep = 0;
    sosCurrentCycle = 0;

    int pattern = strobePattern();
    if (pattern == PSStrobePatternSOS) {
        sosRunning = true;
        sosTotalCycles = strobeSOSCycles();
        dispatch_async(strobeQueue, ^{
            sosDoStep();
        });
    } else {
        dispatch_async(strobeQueue, ^{
            continuousStrobeTick();
        });
    }
}

static void stopStrobe(void) {
    isStrobeRunning = false;
    sosRunning = false;
    sosCurrentStep = 0;
    sosCurrentCycle = 0;
    isStrobeToggleOn = false;
}

#pragma mark - SetTorchLevel Helpers (Dual-LED)

static void SetTorchLevelHook(int result, CFNumberRef level, HXISPCaptureStreamRef stream, HXISPCaptureGroupRef group, HXISPCaptureDeviceRef device) {
    if (!result && level && amberMode()) {
        CFMutableDictionaryRef dict = CFDictionaryCreateMutable(NULL, 0, &kCFCopyStringDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        int val = 100;
        CFNumberRef threshold = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &val);
        CFDictionaryAddValue(dict, CFSTR("WarmLEDPercentile"), threshold);
        if (SetTorchColorWithGroup)
            SetTorchColorWithGroup(dict, stream, group, device);
        else
            SetTorchColor(dict, stream, device);
        CFRelease(threshold);
        CFRelease(dict);
    }
}

#pragma mark - Hook functions

// Dual-LED: SetTorchLevel
static int hook_SetTorchLevel(CFNumberRef level, HXISPCaptureStreamRef stream, HXISPCaptureDeviceRef device) {
    int result = orig_SetTorchLevel(level, stream, device);

    int intLevel = 0;
    if (level) CFNumberGetValue(level, kCFNumberIntType, &intLevel);

    savedStream = stream;
    savedDevice = device;
    savedGroup = NULL;
    savedHasGroup = false;
    strobeSavedLevel = intLevel;
    hasDualLED = true;
    hasQuadLED = false;

    SetTorchLevelHook(result, level, stream, NULL, device);

    if (intLevel > 0) {
        if (strobeEnabled() && !isStrobeRunning)
            startStrobe();
    } else {
        stopStrobe();
    }

    return result;
}

// Dual-LED: SetTorchLevelWithGroup
static int hook_SetTorchLevelWithGroup(CFNumberRef level, HXISPCaptureStreamRef stream, HXISPCaptureGroupRef group, HXISPCaptureDeviceRef device) {
    int result = orig_SetTorchLevelWithGroup(level, stream, group, device);

    int intLevel = 0;
    if (level) CFNumberGetValue(level, kCFNumberIntType, &intLevel);

    savedStream = stream;
    savedDevice = device;
    savedGroup = group;
    savedHasGroup = true;
    strobeSavedLevel = intLevel;
    hasDualLED = true;
    hasQuadLED = false;

    SetTorchLevelHook(result, level, stream, group, device);

    if (intLevel > 0) {
        if (strobeEnabled() && !isStrobeRunning)
            startStrobe();
    } else {
        stopStrobe();
    }

    return result;
}

// Dual-LED: SetTorchColorMode - force mode when Amber mode is Both
static int hook_SetTorchColorMode(void *arg0, unsigned int arg1, unsigned short mode, unsigned short level) {
    SInt32 aMode = amberMode();
    unsigned short newMode = (aMode == PSAmberModeBoth) ? 1 : mode;
    return orig_SetTorchColorMode(arg0, arg1, newMode, level);
}

// Quad-LED: SetIndividualTorchLEDLevels
static int hook_SetIndividualTorchLEDLevels(void *arg0, unsigned int arg1, unsigned int levels) {
    PSAmberMode mode = (PSAmberMode)amberMode();
    unsigned int finalLevels = levels && mode ? (mode == PSAmberModeBoth ? (levels | (levels >> 8)) : (levels >> 8)) : levels;

    savedQuadArg0 = arg0;
    savedQuadArg1 = arg1;
    savedQuadLevels = finalLevels;
    hasQuadLED = true;
    hasDualLED = false;

    int intLevel = levels & 0xFF;
    strobeSavedLevel = intLevel;

    if (levels > 0 && strobeEnabled()) {
        if (!isStrobeRunning) {
            // First call: turn on normally, then start strobe
            int result = orig_SetIndividualTorchLEDLevels(arg0, arg1, finalLevels);
            startStrobe();
            return result;
        }
        // Strobe already running, ignore intermediate level changes during strobe
        return 0;
    } else if (levels == 0) {
        stopStrobe();
    }

    return orig_SetIndividualTorchLEDLevels(arg0, arg1, finalLevels);
}

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
        int HVer = 0;
        void *IOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (IOKit) {
            mach_port_t *kIOMasterPortDefault = (mach_port_t *)dlsym(IOKit, "kIOMasterPortDefault");
            CFMutableDictionaryRef (*IOServiceMatching)(const char *) = (CFMutableDictionaryRef (*)(const char *))dlsym(IOKit, "IOServiceMatching");
            mach_port_t (*IOServiceGetMatchingService)(mach_port_t, CFDictionaryRef) = (mach_port_t (*)(mach_port_t, CFDictionaryRef))dlsym(IOKit, "IOServiceGetMatchingService");
            kern_return_t (*IOObjectRelease)(mach_port_t) = (kern_return_t (*)(mach_port_t))dlsym(IOKit, "IOObjectRelease");
            if (kIOMasterPortDefault && IOServiceGetMatchingService && IOObjectRelease) {
                int hvers[] = { 13, 10, 9, 6 };
                char AppleHXCamIn[14];
                for (int i = 0; i < sizeof(hvers) / sizeof(hvers[0]); ++i) {
                    snprintf(AppleHXCamIn, sizeof(AppleHXCamIn), "AppleH%dCamIn", hvers[i]);
                    mach_port_t hx = IOServiceGetMatchingService(*kIOMasterPortDefault, IOServiceMatching(AppleHXCamIn));
                    if (hx) {
                        IOObjectRelease(hx);
                        HVer = hvers[i];
                        break;
                    }
                }
            }
            dlclose(IOKit);
            HBLogDebug(@"Detected ISP version: %d", HVer);
        }
        if (HVer == 0) return;

        char imagePath[49];
        snprintf(imagePath, sizeof(imagePath), "/System/Library/MediaCapture/H%dISP.mediacapture", HVer);
        void *hxHandle = dlopen(imagePath, RTLD_NOW);
        if (!hxHandle) {
            HBLogDebug(@"Failed to dlopen %s", imagePath);
            return;
        }

        bool quadLED = false;
        bool dualLED = false;

        switch (HVer) {
            case 9: {
                SetTorchLevel = (int (*)(CFNumberRef, HXISPCaptureStreamRef, HXISPCaptureDeviceRef))dlsym(hxHandle, "__ZL13SetTorchLevelPKvP18H9ISPCaptureStreamP18H9ISPCaptureDevice");
                if (SetTorchLevel == NULL)
                    SetTorchLevelWithGroup = (int (*)(CFNumberRef, HXISPCaptureStreamRef, HXISPCaptureGroupRef, HXISPCaptureDeviceRef))dlsym(hxHandle, "__ZL13SetTorchLevelPKvP18H9ISPCaptureStreamP17H9ISPCaptureGroupP18H9ISPCaptureDevice");
                GetCFPreferenceNumber = (SInt32 (*)(CFStringRef const, CFStringRef const, SInt32))dlsym(hxHandle, "__ZN5H9ISP26H9ISPGetCFPreferenceNumberEPK10__CFStringS2_i");
                SetIndividualTorchLEDLevels = (int (*)(void *, unsigned int, unsigned int))dlsym(hxHandle, "__ZN5H9ISP11H9ISPDevice27SetIndividualTorchLEDLevelsEjj");
                break;
            }
            case 6: {
                SetTorchLevel = (int (*)(CFNumberRef, HXISPCaptureStreamRef, HXISPCaptureDeviceRef))dlsym(hxHandle, "__ZL13SetTorchLevelPKvP18H6ISPCaptureStreamP18H6ISPCaptureDevice");
                GetCFPreferenceNumber = (SInt32 (*)(CFStringRef const, CFStringRef const, SInt32))dlsym(hxHandle, "__ZN5H6ISP26H6ISPGetCFPreferenceNumberEPK10__CFStringS2_i");
                SetTorchColor = (int (*)(CFMutableDictionaryRef, HXISPCaptureStreamRef, HXISPCaptureDeviceRef))dlsym(hxHandle, "__ZL13SetTorchColorPKvP18H6ISPCaptureStreamP18H6ISPCaptureDevice");
                SetTorchColorMode = (int (*)(void *, unsigned int, unsigned short, unsigned short))dlsym(hxHandle, "__ZN5H6ISP11H6ISPDevice17SetTorchColorModeEjtt");
                break;
            }
            default: {
                char sym[128];
                snprintf(sym, sizeof(sym), "__ZL13SetTorchLevelPKvP19H%dISPCaptureStreamP18H%dISPCaptureGroupP19H%dISPCaptureDevice", HVer, HVer, HVer);
                SetTorchLevelWithGroup = (int (*)(CFNumberRef, HXISPCaptureStreamRef, HXISPCaptureGroupRef, HXISPCaptureDeviceRef))dlsym(hxHandle, sym);
                if (SetTorchLevelWithGroup == NULL) {
                    snprintf(sym, sizeof(sym), "__ZL13SetTorchLevelPKvP19H%dISPCaptureStreamP19H%dISPCaptureDevice", HVer, HVer);
                    SetTorchLevel = (int (*)(CFNumberRef, HXISPCaptureStreamRef, HXISPCaptureDeviceRef))dlsym(hxHandle, sym);
                }
                snprintf(sym, sizeof(sym), "__ZN6H%dISP27H%dISPGetCFPreferenceNumberEPK10__CFStringS2_i", HVer, HVer);
                GetCFPreferenceNumber = (SInt32 (*)(CFStringRef const, CFStringRef const, SInt32))dlsym(hxHandle, sym);
                snprintf(sym, sizeof(sym), "__ZN6H%dISP12H%dISPDevice27SetIndividualTorchLEDLevelsEjj", HVer, HVer);
                SetIndividualTorchLEDLevels = (int (*)(void *, unsigned int, unsigned int))dlsym(hxHandle, sym);
                snprintf(sym, sizeof(sym), "__ZL13SetTorchColorPKvP19H%dISPCaptureStreamP18H%dISPCaptureGroupP19H%dISPCaptureDevice", HVer, HVer, HVer);
                SetTorchColorWithGroup = (int (*)(CFMutableDictionaryRef, HXISPCaptureStreamRef, HXISPCaptureGroupRef, HXISPCaptureDeviceRef))dlsym(hxHandle, sym);
                snprintf(sym, sizeof(sym), "__ZN6H%dISP12H%dISPDevice17SetTorchColorModeEjtt", HVer, HVer);
                SetTorchColorMode = (int (*)(void *, unsigned int, unsigned short, unsigned short))dlsym(hxHandle, sym);
                break;
            }
        }

        HBLogDebug(@"SetTorchLevel: %d, SetTorchLevelWithGroup: %d", SetTorchLevel != NULL, SetTorchLevelWithGroup != NULL);
        HBLogDebug(@"GetCFPreferenceNumber: %d, SetIndividualTorchLEDLevels: %d", GetCFPreferenceNumber != NULL, SetIndividualTorchLEDLevels != NULL);

        // Install hooks via MSHookFunction to get access to original function pointers
        if (SetIndividualTorchLEDLevels != NULL) {
            quadLED = true;
            MSHookFunction((void *)SetIndividualTorchLEDLevels, (void *)hook_SetIndividualTorchLEDLevels, (void **)&orig_SetIndividualTorchLEDLevels);
            HBLogDebug(@"Hooked SetIndividualTorchLEDLevels (Quad-LED)");
        }

        if (SetTorchLevel != NULL) {
            dualLED = true;
            MSHookFunction((void *)SetTorchLevel, (void *)hook_SetTorchLevel, (void **)&orig_SetTorchLevel);
            HBLogDebug(@"Hooked SetTorchLevel (Dual-LED)");
        }

        if (SetTorchLevelWithGroup != NULL) {
            dualLED = true;
            MSHookFunction((void *)SetTorchLevelWithGroup, (void *)hook_SetTorchLevelWithGroup, (void **)&orig_SetTorchLevelWithGroup);
            HBLogDebug(@"Hooked SetTorchLevelWithGroup (Dual-LED)");
        }

        if (SetTorchColorMode != NULL) {
            MSHookFunction((void *)SetTorchColorMode, (void *)hook_SetTorchColorMode, (void **)&orig_SetTorchColorMode);
            HBLogDebug(@"Hooked SetTorchColorMode (Dual-LED)");
        }

        if (quadLED) {
            hasQuadLED = true;
            HBLogDebug(@"Strobe: Quad-LED mode");
        } else if (dualLED) {
            hasDualLED = true;
            HBLogDebug(@"Strobe: Dual-LED mode");
        }
    }
}
