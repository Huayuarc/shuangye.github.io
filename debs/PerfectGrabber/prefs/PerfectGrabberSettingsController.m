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
    if ([key isEqualToString:@"GrabberStyle"]) {
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
    if (![self isChoiceController]) return;
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSNumber *value = [specifier propertyForKey:PSValueKey];
    NSString *key = [self.specifier propertyForKey:PGChoiceKey];
    NSNumber *selected = PGReadValue(key, @0);
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
                      @"EnabledSwipeUpBackgroundColor", @"SwipeUpBackgroundColor",
                      @"TwoLine", @"FontSize", @"EnabledBackgroundColor", @"BackgroundColor"];
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
