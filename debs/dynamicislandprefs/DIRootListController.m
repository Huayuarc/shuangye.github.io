#import "DIRootListController.h"
#import <Preferences/PSSpecifier.h>
#define kPrefsID   @"com.dynamicisland.tweak"

static NSString *DIPrefsLocalizedString(NSString *key) {
    NSBundle *bundle = [NSBundle bundleForClass:[DIRootListController class]];
    NSString *value = [bundle localizedStringForKey:key value:key table:nil];
    return value ?: key;
}

@implementation DIRootListController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = DIPrefsLocalizedString(@"DI_PREFS_TITLE");
    }
    return self;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    [self postPrefsChanged];
}

- (void)postPrefsChanged {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.dynamicisland.tweak/prefsChanged"),
                                         NULL, NULL, YES);
}

- (void)writePreferences:(NSDictionary *)preferences toUserDefaults:(NSUserDefaults *)userDefaults {
    [userDefaults setPersistentDomain:preferences forName:kPrefsID];
    [userDefaults synchronize];
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsID);
}

// 默认值表（key → default）
- (NSDictionary *)defaultValues {
    return @{
        @"islandEnabled":      @NO,
        @"yOffset":            @45,
        @"compactW":           @155,
        @"compactH":           @35,
        @"expandedW":          @340,
        @"fullW":              @370,
        @"fullH":              @175,
        @"reappearDelay":      @1,
        @"notificationEnabled": @NO,
        @"notifDuration":      @3,
        @"mediaCornerRadius":  @18,
        @"notifCornerRadius":  @22,
        @"borderEnabled":      @NO,
        @"borderWidth":        @1.5,
        @"borderR":            @255,
        @"borderG":            @255,
        @"borderB":            @255,
    };
}

// 「保存设置」按钮：把当前 NSUserDefaults 全部 dump 写盘，再发 Darwin 通知
- (void)saveAllPrefs {
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefsID];
    NSDictionary *current = [ud dictionaryRepresentation];

    NSMutableDictionary *toSave = [NSMutableDictionary dictionaryWithDictionary:[self defaultValues]];
    for (NSString *k in [self defaultValues].allKeys) {
        id v = current[k];
        if (v) toSave[k] = v;
    }

    [self writePreferences:toSave toUserDefaults:ud];

    [self postPrefsChanged];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:DIPrefsLocalizedString(@"DI_SAVE_DONE_TITLE")
                                                                   message:[NSString stringWithFormat:DIPrefsLocalizedString(@"DI_SAVE_DONE_MESSAGE"), (unsigned long)toSave.count, kPrefsID]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:DIPrefsLocalizedString(@"DI_OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 「恢复默认值」按钮
- (void)resetAllPrefs {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:DIPrefsLocalizedString(@"DI_RESET_CONFIRM_TITLE")
                                                                   message:DIPrefsLocalizedString(@"DI_RESET_CONFIRM_MESSAGE")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:DIPrefsLocalizedString(@"DI_CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:DIPrefsLocalizedString(@"DI_RESET_CONFIRM_ACTION") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSDictionary *defaults = [self defaultValues];
        NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefsID];
        [self writePreferences:defaults toUserDefaults:ud];
        [self postPrefsChanged];
        [self reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
