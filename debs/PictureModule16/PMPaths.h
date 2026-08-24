#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *PMDataRoot(void);
FOUNDATION_EXPORT NSString *PMPrefsPath(NSString *domain);
FOUNDATION_EXPORT NSDictionary *PMReadDomain(NSString *domain);
FOUNDATION_EXPORT BOOL PMWriteDomainValue(NSString *domain, NSString *key, id value);
FOUNDATION_EXPORT void PMPrepareAndMigrate(void);
