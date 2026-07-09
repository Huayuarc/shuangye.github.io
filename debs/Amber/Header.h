#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

// Amber LED mode
CFStringRef const amberModeKey = CFSTR("PSLEDMode");
CFStringRef const kDomain = CFSTR("com.apple.coremedia");

typedef NS_ENUM(int, PSAmberMode) {
    PSAmberModeDefault = 0,
    PSAmberModeOrange,
    PSAmberModeBoth,
    PSAmberModeCount
};

// Strobe settings (stored in com.ps.amber domain)
CFStringRef const strobeDomain = CFSTR("com.ps.amber");
CFStringRef const strobeEnabledKey = CFSTR("PSStrobeEnabled");
CFStringRef const strobeFrequencyKey = CFSTR("PSStrobeFrequency");
CFStringRef const strobePatternKey = CFSTR("PSStrobePattern");
CFStringRef const strobeSOSCyclesKey = CFSTR("PSStrobeSOSCycles");

typedef NS_ENUM(int, PSStrobePattern) {
    PSStrobePatternContinuous = 0,
    PSStrobePatternSOS,
    PSStrobePatternCount
};
