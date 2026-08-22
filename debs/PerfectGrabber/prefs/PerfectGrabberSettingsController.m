#import "PerfectGrabberSettingsController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <math.h>
#import <spawn.h>

extern char **environ;

static NSString *const PGDomain = @"com.netskao.perfectgrabber";
static CFStringRef const PGChanged = CFSTR("com.netskao.perfectgrabber.settingschanged");
static NSString *const PGChoiceKey = @"PGChoiceKey";
static NSString *const PGChoiceTitleKey = @"PGChoiceTitle";

static id PGReadValue(NSString *key, id fallback) {
    CFPreferencesSynchronize((__bridge CFStringRef)PGDomain,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPropertyListRef value = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                      (__bridge CFStringRef)PGDomain,
                                                      kCFPreferencesCurrentUser,
                                                      kCFPreferencesAnyHost);
    return CFBridgingRelease(value) ?: fallback;
}

static void PGWriteValue(NSString *key, id value) {
    CFPreferencesSetValue((__bridge CFStringRef)key,
                          (__bridge CFPropertyListRef)value,
                          (__bridge CFStringRef)PGDomain,
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesSynchronize((__bridge CFStringRef)PGDomain,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), PGChanged,
                                         NULL, NULL, YES);
}

@interface PerfectGrabberSettingsController () <UIColorPickerViewControllerDelegate>
@property (nonatomic, copy) NSString *activeColorKey;
@end

@implementation PerfectGrabberSettingsController

- (BOOL)isChoiceController {
    return [[self.specifier propertyForKey:PGChoiceKey] length] > 0;
}

- (NSMutableArray *)choiceSpecifiers {
    NSString *key = [self.specifier propertyForKey:PGChoiceKey];
    NSString *title = [self.specifier propertyForKey:PGChoiceTitleKey];
    NSArray *values = nil;
    NSArray *titles = nil;
    if ([key isEqualToString:@"AutoCloseDelay"]) {
        values = @[@1, @2, @3, @4, @5, @6];
        titles = @[@"1 秒", @"2 秒", @"3 秒", @"4 秒", @"5 秒", @"6 秒"];
    } else if ([key isEqualToString:@"GrabberStyle"]) {
        values = @[@0, @1];
        titles = @[@"居中", @"靠顶部"];
    } else {
        values = @[@0, @1, @2];
        titles = @[@"常规", @"粗体", @"斜体"];
    }
    NSMutableArray *items = [NSMutableArray array];
    [items addObject:[PSSpecifier groupSpecifierWithName:title ?: @""]];
    for (NSUInteger index = 0; index < values.count; index++) {
        PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:titles[index]
                                                               target:self
                                                                  set:NULL
                                                                  get:NULL
                                                               detail:Nil
                                                                 cell:PSListItemCell
                                                                 edit:Nil];
        [item setProperty:values[index] forKey:PSValueKey];
        [item setProperty:key forKey:PSKeyNameKey];
        [items addObject:item];
    }
    return items;
}

- (void)tableView:(UITableView *)tableView
 willDisplayCell:(UITableViewCell *)cell
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![self isChoiceController]) {
        return;
    }
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSNumber *value = [specifier propertyForKey:PSValueKey];
    NSString *key = [self.specifier propertyForKey:PGChoiceKey];
    NSNumber *selected = PGReadValue(key, [key isEqualToString:@"AutoCloseDelay"] ? @3 : @0);
    if ([cell respondsToSelector:@selector(setChecked:)]) {
        [(PSTableCell *)cell setChecked:[value integerValue] == [selected integerValue]];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![self isChoiceController]) {
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
        return;
    }
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSNumber *value = [specifier propertyForKey:PSValueKey];
    NSString *key = [self.specifier propertyForKey:PGChoiceKey];
    if ([value isKindOfClass:NSNumber.class]) {
        PGWriteValue(key, value);
        [tableView reloadData];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (PSSpecifier *)preferenceNamed:(NSString *)name key:(NSString *)key defaultValue:(id)defaultValue cell:(PSCellType)cell {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                            target:self
                                                               set:@selector(setPreferenceValue:specifier:)
                                                               get:@selector(readPreferenceValue:)
                                                            detail:Nil
                                                              cell:cell
                                                              edit:Nil];
    [specifier setProperty:key forKey:PSKeyNameKey];
    [specifier setProperty:PGDomain forKey:PSDefaultsKey];
    [specifier setProperty:defaultValue forKey:PSDefaultValueKey];
    [specifier setProperty:(__bridge NSString *)PGChanged forKey:PSValueChangedNotificationKey];
    return specifier;
}

- (PSSpecifier *)segmentNamed:(NSString *)name key:(NSString *)key defaultValue:(NSNumber *)defaultValue
                        values:(NSArray *)values titles:(NSArray *)titles {
    PSSpecifier *specifier = [self preferenceNamed:name key:key defaultValue:defaultValue cell:PSSegmentCell];
    [specifier setProperty:values forKey:@"validValues"];
    [specifier setProperty:titles forKey:@"validTitles"];
    // Keep aliases for older Preferences builds that use the plist field names.
    [specifier setProperty:values forKey:@"values"];
    [specifier setProperty:titles forKey:@"titles"];
    return specifier;
}

- (PSSpecifier *)choiceLinkNamed:(NSString *)name key:(NSString *)key {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                            detail:PerfectGrabberSettingsController.class
                                                              cell:PSLinkCell
                                                              edit:Nil];
    [specifier setProperty:key forKey:PGChoiceKey];
    [specifier setProperty:name forKey:PGChoiceTitleKey];
    return specifier;
}

- (PSSpecifier *)buttonNamed:(NSString *)name action:(SEL)action {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL
                                                            detail:Nil cell:PSButtonCell edit:Nil];
    specifier.buttonAction = action;
    return specifier;
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    if ([self isChoiceController]) {
        _specifiers = [self choiceSpecifiers];
        return _specifiers;
    }
    NSMutableArray *items = [NSMutableArray array];

    PSSpecifier *main = [PSSpecifier groupSpecifierWithName:@"PerfectGrabber"];
    [main setProperty:@"媒体卡片设置会在下一次下拉时立即生效。" forKey:PSFooterTextGroupKey];
    [items addObject:main];
    [items addObject:[self preferenceNamed:@"启用插件" key:@"EnabledPerfectGrabber" defaultValue:@NO cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"震动反馈" key:@"VibrationFeedback" defaultValue:@YES cell:PSSwitchCell]];

    [items addObject:[PSSpecifier groupSpecifierWithName:@"触发方式"]];
    [items addObject:[self preferenceNamed:@"下拉时显示媒体卡片" key:@"ShowOnSwipeUp" defaultValue:@YES cell:PSSwitchCell]];
    [items addObject:[self segmentNamed:@"媒体卡片自动关闭" key:@"AutoCloseDelay" defaultValue:@3
                                 values:@[@1, @2, @3, @4, @5, @6]
                                 titles:@[@"1秒", @"2秒", @"3秒", @"4秒", @"5秒", @"6秒"]]];

    [items addObject:[PSSpecifier groupSpecifierWithName:@"显示"]];
    [items addObject:[self preferenceNamed:@"使用 12 小时制" key:@"Disable24H" defaultValue:@NO cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"充电图标" key:@"ChargingIcon" defaultValue:@YES cell:PSSwitchCell]];
    [items addObject:[self choiceLinkNamed:@"布局样式" key:@"GrabberStyle"]];
    [items addObject:[self choiceLinkNamed:@"字体样式" key:@"FontStyle"]];
    [items addObject:[self buttonNamed:@"文字颜色" action:@selector(chooseTextColor)]];
    PSSpecifier *statusSize = [self preferenceNamed:@"时间·温度·电量字体大小" key:@"StatusFontSize" defaultValue:@15.0 cell:PSSliderCell];
    [statusSize setProperty:@11.0 forKey:PSControlMinimumKey];
    [statusSize setProperty:@20.0 forKey:PSControlMaximumKey];
    [statusSize setProperty:@YES forKey:@"showValue"];
    [items addObject:statusSize];
    [items addObject:[self segmentNamed:@"状态信息位置" key:@"StatusPosition" defaultValue:@0
                                 values:@[@0, @1] titles:@[@"音乐下方", @"音乐上方"]]];

    [items addObject:[PSSpecifier groupSpecifierWithName:@"媒体卡片背景"]];
    [items addObject:[self preferenceNamed:@"启用自定义背景" key:@"EnabledSwipeUpBackgroundColor" defaultValue:@NO cell:PSSwitchCell]];
    [items addObject:[self buttonNamed:@"媒体卡片背景颜色" action:@selector(chooseSwipeUpBackgroundColor)]];

    [items addObject:[PSSpecifier groupSpecifierWithName:@"操作"]];
    [items addObject:[self buttonNamed:@"恢复默认设置" action:@selector(onResetSettings)]];
    [items addObject:[self buttonNamed:@"注销桌面" action:@selector(onRespring)]];

    PSSpecifier *footer = [PSSpecifier emptyGroupSpecifier];
    [footer setProperty:@"Ntonia-PreferenceLoader 1.1-17" forKey:PSFooterTextGroupKey];
    [items addObject:footer];
    _specifiers = items;
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:PSKeyNameKey];
    return PGReadValue(key, [specifier propertyForKey:PSDefaultValueKey]);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:PSKeyNameKey];
    if ([key isEqualToString:@"AutoCloseDelay"]) {
        value = @(MAX(1, MIN(6, (NSInteger)lround([value doubleValue]))));
    } else if ([key isEqualToString:@"StatusPosition"]) {
        value = @([value integerValue] == 1 ? 1 : 0);
    }
    PGWriteValue(key, value);
}

- (UIColor *)colorForHex:(NSString *)hex fallback:(UIColor *)fallback {
    NSString *clean = [[hex ?: @"" stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    if (clean.length != 6) return fallback;
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb] || !scanner.isAtEnd) return fallback;
    return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                           green:((rgb >> 8) & 0xff) / 255.0
                            blue:(rgb & 0xff) / 255.0 alpha:1.0];
}

- (NSString *)hexForColor:(UIColor *)color {
    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return @"#FFFFFF";
    return [NSString stringWithFormat:@"#%02lX%02lX%02lX",
            lround(red * 255.0), lround(green * 255.0), lround(blue * 255.0)];
}

- (void)showColorPickerForKey:(NSString *)key fallback:(UIColor *)fallback {
    self.activeColorKey = key;
    NSString *stored = PGReadValue(key, nil);
    UIColorPickerViewController *picker = [UIColorPickerViewController new];
    picker.delegate = self;
    picker.supportsAlpha = NO;
    picker.selectedColor = [self colorForHex:stored fallback:fallback];
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)chooseTextColor {
    [self showColorPickerForKey:@"TextColor" fallback:UIColor.whiteColor];
}

- (void)chooseBackgroundColor {
    [self showColorPickerForKey:@"BackgroundColor"
                       fallback:[UIColor colorWithRed:0 green:0.75 blue:1 alpha:1]];
}

- (void)chooseSwipeUpBackgroundColor {
    [self showColorPickerForKey:@"SwipeUpBackgroundColor"
                       fallback:[UIColor colorWithRed:0 green:0.68 blue:1 alpha:1]];
}

- (void)storeSelectedColor:(UIColor *)color {
    if (!self.activeColorKey.length) return;
    PGWriteValue(self.activeColorKey, [self hexForColor:color]);
}

- (void)colorPickerViewController:(UIColorPickerViewController *)viewController
                   didSelectColor:(UIColor *)color
                     continuously:(BOOL)continuously {
    [self storeSelectedColor:color];
}

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)viewController {
    [self storeSelectedColor:viewController.selectedColor];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    [self storeSelectedColor:viewController.selectedColor];
    self.activeColorKey = nil;
}

- (void)onResetSettings {
    NSArray *keys = @[@"EnabledPerfectGrabber", @"VibrationFeedback", @"ShowOnSwipeUp",
                      @"AutoCloseDelay", @"Disable24H", @"ChargingIcon", @"TextColor",
                      @"GrabberStyle", @"FontStyle", @"StatusFontSize", @"StatusPosition",
                      @"EnabledSwipeUpBackgroundColor",
                      @"SwipeUpBackgroundColor", @"TwoLine", @"FontSize",
                      @"EnabledBackgroundColor", @"BackgroundColor"];
    for (NSString *key in keys) {
        CFPreferencesSetValue((__bridge CFStringRef)key, NULL,
                              (__bridge CFStringRef)PGDomain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    }
    CFPreferencesSynchronize((__bridge CFStringRef)PGDomain,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), PGChanged,
                                         NULL, NULL, YES);
    [self reloadSpecifiers];
}

- (NSString *)jailbreakRoot {
    NSString *executable = [NSBundle bundleForClass:self.class].executablePath;
    NSRange marker = [executable rangeOfString:@"/Library/PreferenceBundles/"];
    return marker.location == NSNotFound ? @"" : [executable substringToIndex:marker.location];
}

- (void)onRespring {
    NSString *root = [self jailbreakRoot];
    NSArray<NSString *> *candidates = @[
        [root stringByAppendingPathComponent:@"usr/bin/sbreload"],
        [root stringByAppendingPathComponent:@"usr/bin/killall"],
        @"/usr/bin/sbreload", @"/usr/bin/killall"
    ];
    for (NSString *path in candidates) {
        if (access(path.fileSystemRepresentation, X_OK) != 0) continue;
        pid_t pid = 0;
        BOOL killall = [path.lastPathComponent isEqualToString:@"killall"];
        char *const sbreloadArgs[] = {(char *)path.fileSystemRepresentation, NULL};
        char *const killallArgs[] = {(char *)path.fileSystemRepresentation, "-9", "SpringBoard", NULL};
        posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL,
                    killall ? killallArgs : sbreloadArgs, environ);
        return;
    }
}

@end
