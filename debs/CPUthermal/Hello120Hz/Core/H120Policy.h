#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
float H120NormalizeFPS(float fps);
uint32_t H120CadenceForFPS(float fps);
bool H120SystemAllowsOverride(bool enabled, bool lowPower, int thermalState);
uint32_t H120ChooseCadence(uint32_t original, uint32_t policy, uint32_t hardwareMinimum);
#ifdef __cplusplus
}
#endif
