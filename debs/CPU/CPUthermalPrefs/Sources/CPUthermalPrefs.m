#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "Tweak.h"

#define PREFS_PATH rootlessPath(@"/var/mobile/Library/Preferences/com.huayuarc.cputhermal-prefs.plist")

@interface CPUthermalPrefs : PSListController
@end

@implementation CPUthermalPrefs

- (NSArray *)specifiers {
    if (![self valueForKey:@"_specifiers"]) {
        NSArray *specs = [self loadSpecifiersFromPlistName:@"Root" target:self];
        [self setValue:specs forKey:@"_specifiers"];
    }
    return [self valueForKey:@"_specifiers"];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSString *key = [specifier.properties objectForKey:@"key"];
    id defaultValue = [specifier.properties objectForKey:@"default"];
    id value = [prefs objectForKey:key];
    return value ?: defaultValue;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    if (!prefs) prefs = [NSMutableDictionary dictionary];

    NSString *key = [specifier.properties objectForKey:@"key"];
    if (key) {
        [prefs setObject:value forKey:key];
        [prefs writeToFile:PREFS_PATH atomically:YES];
    }

    if ([key isEqualToString:@"thermalPuppetValue"]) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.huayuarc.cputhermal-executePuppetEvent"),
            NULL, NULL, YES
        );
    }
}

@end
