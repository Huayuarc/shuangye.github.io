#import <Foundation/Foundation.h>

/// 统一的偏好设置管理（直接读写 plist，跨进程共享）
@interface EQPrefs : NSObject

+ (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue;
+ (double)doubleForKey:(NSString *)key defaultValue:(double)defaultValue;
+ (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)defaultValue;
+ (id)objectForKey:(NSString *)key;
+ (void)setObject:(id)value forKey:(NSString *)key;
+ (void)synchronize;

@end

static NSString *const kEQPrefsPath = @"/var/mobile/Library/Preferences/com.shuangye.earthquake.plist";
static NSString *const kEQEventPath = @"/var/mobile/Library/Preferences/com.shuangye.earthquake.latest.plist";
static NSString *const kEQProcessedPath = @"/var/mobile/Library/Preferences/com.shuangye.earthquake.processed.plist";

@implementation EQPrefs

+ (NSMutableDictionary *)_dict {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kEQPrefsPath];
    if (!d) d = [NSMutableDictionary dictionary];
    return d;
}

+ (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    id val = [self _dict][key];
    return val ? [val boolValue] : defaultValue;
}

+ (double)doubleForKey:(NSString *)key defaultValue:(double)defaultValue {
    id val = [self _dict][key];
    return val ? [val doubleValue] : defaultValue;
}

+ (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)defaultValue {
    id val = [self _dict][key];
    return val ? [val integerValue] : defaultValue;
}

+ (id)objectForKey:(NSString *)key {
    return [self _dict][key];
}

+ (void)setObject:(id)value forKey:(NSString *)key {
    NSMutableDictionary *d = [self _dict];
    if (value) {
        d[key] = value;
    } else {
        [d removeObjectForKey:key];
    }
    [d writeToFile:kEQPrefsPath atomically:YES];
}

+ (void)synchronize {}

@end
