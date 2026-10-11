#ifndef SJG_SCRIPT_FEATURES_H
#define SJG_SCRIPT_FEATURES_H
#import <Foundation/Foundation.h>

/* Synchronous, serialized on a private queue. All options default to NO.
 * Apply never cleans caches. Call CleanCaches only from an explicit manual
 * notification handler; Restore must be called on an orderly helper stop. */
FOUNDATION_EXPORT void SJGApplyScriptSettings(NSDictionary *settings);
FOUNDATION_EXPORT NSDictionary *SJGScriptStatus(void);
FOUNDATION_EXPORT NSDictionary *SJGCleanCaches(NSDictionary *settings);
FOUNDATION_EXPORT void SJGRestoreScriptSettings(void);
#endif
