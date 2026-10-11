#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Runs one bounded, synchronous memory-trim pass on the calling thread.

 Accepted modes are exactly `normal` and `deep` (case-insensitive). The engine
 serializes passes inside the process and returns `stopReason = busy` rather
 than waiting when another pass is active.
 */
FOUNDATION_EXPORT NSDictionary<NSString *, id> *SJGRunMemoryTrim(NSString *mode);

NS_ASSUME_NONNULL_END
