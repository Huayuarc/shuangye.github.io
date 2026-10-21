#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum H120RecordingHook {
    H120RecordingCaptureFactory = 1u << 0,
    H120RecordingAssetWriterInput = 1u << 1,
    H120RecordingStartSession = 1u << 2,
    H120RecordingMovieWriterSetup = 1u << 3
};
uint32_t H120InstallRecordingHooks(void);
#ifdef __cplusplus
}
#endif
