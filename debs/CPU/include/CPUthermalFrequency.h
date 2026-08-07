#ifndef CPUTHERMAL_FREQUENCY_H
#define CPUTHERMAL_FREQUENCY_H

#import <Foundation/Foundation.h>

static const int kCPUthermalDefaultLowPowerLockMHz = 1380;
static const int kCPUthermalMinimumCPUFrequencyMHz = 300;
static const int kCPUthermalMaximumCPUFrequencyMHz = 6000;

static inline int CPUthermalNormalizedLowPowerLockMHz(int requestedMHz) {
    if (requestedMHz >= kCPUthermalMinimumCPUFrequencyMHz &&
        requestedMHz <= kCPUthermalMaximumCPUFrequencyMHz) {
        return requestedMHz;
    }
    return kCPUthermalDefaultLowPowerLockMHz;
}

static inline int CPUthermalLowPowerLockMHzFromValue(id value) {
    int rawValue = [value intValue];
    if ([value isKindOfClass:[NSNumber class]] && rawValue >= 0 && rawValue <= 2) {
        static const int presetValues[] = {1380, 1428, 1584};
        rawValue = presetValues[rawValue];
    }
    return CPUthermalNormalizedLowPowerLockMHz(rawValue);
}

#endif
