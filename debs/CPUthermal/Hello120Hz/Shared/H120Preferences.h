#pragma once
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString * const H120PreferencesDomain;
FOUNDATION_EXPORT NSString * const H120PreferencesNotification;
FOUNDATION_EXPORT NSString * _Nullable H120JailbreakPath(NSString *logicalPath);
FOUNDATION_EXPORT NSString * _Nullable H120PreferencesPath(void);
FOUNDATION_EXPORT NSDictionary *H120ReadPreferences(void);
FOUNDATION_EXPORT BOOL H120WritePreference(NSString *key, id _Nullable value);
FOUNDATION_EXPORT BOOL H120ReplacePreferences(NSDictionary *preferences);
FOUNDATION_EXPORT void H120PostPreferencesChanged(void);
FOUNDATION_EXPORT CFNotificationCenterRef _Nullable H120DistributedNotificationCenter(void);
NS_ASSUME_NONNULL_END
