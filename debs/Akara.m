#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "AkaraSettings.h"
#import "AkaraCommon.h"

static void akrPrefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo);
static NSNotification *AKRReloadNotification(void);

@implementation AkaraSettings

+ (instancetype)sharedSettings {
    static AkaraSettings *sharedSettings = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedSettings = [[self alloc] init];
    });
    return sharedSettings;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self load];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self, akrPrefsChangedCallback, (__bridge CFStringRef)AKRPrefsChangedNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    return self;
}

- (void)load {
    self.prefs = AKRPreferences();
    self.connectivityRowOrderDictionary = @{
        @"first": self.connectivityFirstRowOrder ?: @"123",
        @"second": self.connectivitySecondRowOrder ?: @"456"
    };
}

- (void)updateAkaraWithNotification:(NSNotification *)notification {
    [self load];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"akaraUpdateNotExpandedSubtitleLabelsNotification" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"akaraUpdateDoubleTextViewSecondaryLabelColorNotification" object:nil];
}

- (id)valueForPreferenceKeys:(NSArray<NSString *> *)keys defaultValue:(id)defaultValue {
    for (NSString *key in keys) {
        id value = self.prefs[key];
        if (value) {
            return value;
        }
    }
    return defaultValue;
}

- (BOOL)boolForPreferenceKeys:(NSArray<NSString *> *)keys defaultValue:(BOOL)defaultValue {
    id value = [self valueForPreferenceKeys:keys defaultValue:nil];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : defaultValue;
}

- (CGFloat)floatForPreferenceKeys:(NSArray<NSString *> *)keys defaultValue:(CGFloat)defaultValue {
    id value = [self valueForPreferenceKeys:keys defaultValue:nil];
    return [value respondsToSelector:@selector(doubleValue)] ? (CGFloat)[value doubleValue] : defaultValue;
}

- (NSInteger)integerForPreferenceKeys:(NSArray<NSString *> *)keys defaultValue:(NSInteger)defaultValue {
    id value = [self valueForPreferenceKeys:keys defaultValue:nil];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : defaultValue;
}

- (BOOL)tweakEnabled { return [self boolForPreferenceKeys:@[@"akaraTweakEnabled", @"tweakEnabled", @"enabled", @"optionEnabled"] defaultValue:YES]; }
- (BOOL)optionEnabled { return self.tweakEnabled; }
- (BOOL)useLargeMode { return [self boolForPreferenceKeys:@[@"akaraUseLargeMode", @"useLargeMode"] defaultValue:NO]; }
- (BOOL)useSEMode { return [self boolForPreferenceKeys:@[@"akaraUseSEMode", @"useSEMode"] defaultValue:NO]; }
- (BOOL)useBackgroundBlur { return [self boolForPreferenceKeys:@[@"akaraUseBackgroundBlur", @"useBackgroundBlur"] defaultValue:YES]; }
- (BOOL)useBackgroundImage { return [self boolForPreferenceKeys:@[@"akaraUseBackgroundImage", @"useBackgroundImage"] defaultValue:NO]; }
- (BOOL)useCustomCornerRadius { return [self boolForPreferenceKeys:@[@"akaraUseCustomCornerRadius", @"useCustomCornerRadius"] defaultValue:NO]; }
- (BOOL)useCustomMaterialViewAlpha { return [self boolForPreferenceKeys:@[@"akaraUseCustomMaterialViewAlpha", @"useCustomMaterialViewAlpha"] defaultValue:NO]; }
- (BOOL)useStaticWifiIcon { return [self boolForPreferenceKeys:@[@"akaraUseStaticWifiIcon", @"useStaticWifiIcon"] defaultValue:NO]; }
- (BOOL)useStaticBluetoothIcon { return [self boolForPreferenceKeys:@[@"akaraUseStaticBluetoothIcon", @"useStaticBluetoothIcon"] defaultValue:NO]; }
- (BOOL)useStaticBrightnessSliderIcon { return [self boolForPreferenceKeys:@[@"akaraUseStaticBrightnessSliderIcon", @"useStaticBrightnessSliderIcon"] defaultValue:NO]; }
- (BOOL)useStaticVolumeSliderIcon { return [self boolForPreferenceKeys:@[@"akaraUseStaticVolumeSliderIcon", @"useStaticVolumeSliderIcon"] defaultValue:NO]; }
- (BOOL)useNativeConnectivityLabels { return [self boolForPreferenceKeys:@[@"akaraUseNativeConnectivityLabels", @"useNativeConnectivityLabels"] defaultValue:YES]; }
- (BOOL)showMediaRadioButton { return [self boolForPreferenceKeys:@[@"akaraShowMediaRadioButton", @"showMediaRadioButton"] defaultValue:NO]; }
- (BOOL)showStatusBar { return [self boolForPreferenceKeys:@[@"akaraShowStatusBar", @"showStatusBar"] defaultValue:NO]; }
- (BOOL)showNotchAndNormalStatusBar { return [self boolForPreferenceKeys:@[@"akaraShowNotchStatusBar", @"akaraShowNotchAndNormalStatusBar", @"showNotchAndNormalStatusBar"] defaultValue:NO]; }
- (BOOL)enableTopRightGesture { return [self boolForPreferenceKeys:@[@"akaraEnableTopRightGesture", @"enableTopRightGesture"] defaultValue:NO]; }
- (BOOL)enableTopRightAndBottomGesture { return [self boolForPreferenceKeys:@[@"akaraEnableTopRightAndBottomGesture", @"enableTopRightAndBottomGesture"] defaultValue:NO]; }
- (BOOL)easeLockScreenGesture { return [self boolForPreferenceKeys:@[@"akaraEaseLockScreenGesture", @"easeLockScreenGesture"] defaultValue:NO]; }
- (BOOL)extraDisableInLandscape { return [self boolForPreferenceKeys:@[@"akaraDisableInLandscapeMode", @"akaraExtraDisableInLandscape", @"extraDisableInLandscape"] defaultValue:NO]; }
- (BOOL)scrollBackToFirstConnectivityPage { return [self boolForPreferenceKeys:@[@"akaraScrollBackToFirstConnectivityPage", @"scrollBackToFirstConnectivityPage"] defaultValue:NO]; }
- (BOOL)akaraCCDismiss { return [self boolForPreferenceKeys:@[@"akaraCCDismiss"] defaultValue:NO]; }
- (BOOL)animateTopConstraintAsNecessary { return [self boolForPreferenceKeys:@[@"akaraAnimateTopConstraintAsNecessary", @"animateTopConstraintAsNecessary"] defaultValue:YES]; }

- (NSInteger)backgroundBlurStyle { return [self integerForPreferenceKeys:@[@"akaraBackgroundBlurStyle", @"backgroundBlurStyle", @"blurOption"] defaultValue:2]; }
- (CGFloat)customCornerRadius { return [self floatForPreferenceKeys:@[@"akaraCustomCornerRadius", @"customCornerRadius"] defaultValue:38.0]; }
- (CGFloat)customMaterialViewAlpha { return [self floatForPreferenceKeys:@[@"akaraCustomMaterialViewAlpha", @"customMaterialViewAlpha"] defaultValue:1.0]; }
- (CGFloat)customMediaHeight { return [self floatForPreferenceKeys:@[@"akaraCustomMediaHeight", @"customMediaHeight"] defaultValue:2.0]; }
- (CGFloat)customMediaWidth { return [self floatForPreferenceKeys:@[@"akaraCustomMediaWidth", @"customMediaWidth"] defaultValue:2.0]; }
- (CGFloat)customSliderHeight { return [self floatForPreferenceKeys:@[@"akaraCustomSliderHeight", @"customSliderHeight"] defaultValue:2.0]; }
- (NSString *)connectivityFirstRowOrder { return [self valueForPreferenceKeys:@[@"akaraConnectivityFirstRowOrder", @"connectivityFirstRowOrder"] defaultValue:@"123"]; }
- (NSString *)connectivitySecondRowOrder { return [self valueForPreferenceKeys:@[@"akaraConnectivitySecondRowOrder", @"connectivitySecondRowOrder"] defaultValue:@"456"]; }
- (NSString *)akBackgroundImage { return [self valueForPreferenceKeys:@[@"akaraBackgroundImage", @"akBackgroundImage"] defaultValue:nil]; }
- (UIImage *)akBackgroundImageView { return self.akBackgroundImage.length ? [UIImage imageWithContentsOfFile:self.akBackgroundImage] : nil; }
- (NSInteger)blurOption { return self.backgroundBlurStyle; }

- (void)dismissAkara:(id)sender {}

@end

static NSNotification *AKRReloadNotification(void) {
    return [NSNotification notificationWithName:@"com.huayuarc.akaraprefs/prefsChanged" object:nil];
}

static void akrPrefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[AkaraSettings sharedSettings] load];
        [[AkaraSettings sharedSettings] updateAkaraWithNotification:AKRReloadNotification()];
    });
}

void updateAkara(void) {
    [[AkaraSettings sharedSettings] updateAkaraWithNotification:AKRReloadNotification()];
}

void reloadPrefValues(void) {
    [[AkaraSettings sharedSettings] load];
}

void loadPrefs(void) {
    [[AkaraSettings sharedSettings] load];
}

BOOL isLocationXOnSides(double location) {
    return location < 64.0;
}

BOOL isLocationXOnSidesLandscape(double location) {
    return location < 64.0;
}

UIImage *scaledImageForModuleName(NSString *moduleName, double scale) {
    NSString *path = [AKRPathInPrefix(@"/Library/Application Support/Akara") stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", moduleName ?: @""]];
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (!image || scale <= 0.0) {
        return image;
    }
    CGSize size = CGSizeMake(image.size.width * scale, image.size.height * scale);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    [image drawInRect:CGRectMake(0.0, 0.0, size.width, size.height)];
    UIImage *scaledImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return scaledImage;
}

void setGlyphImageForRoundButton(id roundButton, UIImage *image) {
    if (!roundButton || !image) {
        return;
    }
    @try {
        [roundButton setValue:image forKey:@"glyphImage"];
    } @catch (__unused NSException *exception) {
    }
}

void disableGlyphImageForRoundButton(id roundButton) {
    if (!roundButton) {
        return;
    }
    @try {
        [roundButton setValue:nil forKey:@"glyphImage"];
    } @catch (__unused NSException *exception) {
    }
}

void lockScreenStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
}

__attribute__((constructor)) static void AkaraInitializer(void) {
    @autoreleasepool {
        [AkaraSettings sharedSettings];
        NSLog(@"[Akara] safe compatibility tweak loaded");
    }
}
