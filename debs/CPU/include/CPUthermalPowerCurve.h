#ifndef CPUTHERMAL_POWER_CURVE_H
#define CPUTHERMAL_POWER_CURVE_H

#include <stddef.h>
#include <stdint.h>

static inline uint64_t CPUthermalReadLittleEndianUnsigned(const uint8_t *bytes, size_t width) {
    if (!bytes || (width != 4 && width != 8)) return 0;
    uint64_t value = 0;
    for (size_t index = 0; index < width; index++) {
        value |= (uint64_t)bytes[index] << (index * 8);
    }
    return value;
}

static inline int CPUthermalFrequencyMHzFromRaw(uint64_t rawFrequency) {
    if (rawFrequency >= 300000000ULL && rawFrequency <= 6000000000ULL) {
        return (int)((rawFrequency + 500000ULL) / 1000000ULL);
    }
    if (rawFrequency >= 300000ULL && rawFrequency <= 6000000ULL) {
        return (int)((rawFrequency + 500ULL) / 1000ULL);
    }
    if (rawFrequency >= 300ULL && rawFrequency <= 6000ULL) {
        return (int)rawFrequency;
    }
    return 0;
}

static inline uint32_t CPUthermalVoltageMillivoltsFromRaw(uint64_t rawVoltage) {
    static const uint32_t scales[] = {1, 10, 100, 1000};
    for (size_t index = 0; index < sizeof(scales) / sizeof(scales[0]); index++) {
        uint32_t scale = scales[index];
        uint64_t minimum = 400ULL * scale;
        uint64_t maximum = 2000ULL * scale;
        if (rawVoltage >= minimum && rawVoltage <= maximum) {
            return (uint32_t)((rawVoltage + scale / 2) / scale);
        }
    }
    return 0;
}

#endif
