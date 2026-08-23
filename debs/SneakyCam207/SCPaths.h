#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *SCPreferencePath(void);
FOUNDATION_EXPORT NSDictionary *SCReadPreferences(void);
FOUNDATION_EXPORT void SCWritePreference(NSString *key, id value);
FOUNDATION_EXPORT NSString *SCCurrentJailbreakRoot(void);
FOUNDATION_EXPORT void SCMigratePreferencesIfNeeded(void);
NS_ASSUME_NONNULL_END
