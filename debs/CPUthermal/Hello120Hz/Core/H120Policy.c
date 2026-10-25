#include "H120Policy.h"

float H120NormalizeFPS(float fps) {

    if (fps == 10.0f || fps == 30.0f || fps == 60.0f || fps == 80.0f) return fps;
    return 120.0f;
}

uint32_t H120CadenceForFPS(float fps) {
    return (uint32_t)(240.0f / H120NormalizeFPS(fps));
}

bool H120SystemAllowsOverride(bool enabled, bool lowPower, int thermalState) {
    return enabled && !lowPower && thermalState < 2;
}

uint32_t H120ChooseCadence(uint32_t original, uint32_t policy, uint32_t hardwareMinimum) {

    if (original <= 1 || !policy || original == policy) return original;
    return policy >= hardwareMinimum ? policy : original;
}
