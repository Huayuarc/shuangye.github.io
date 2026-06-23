#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AkaraSettings : NSObject
{
    NSDictionary *_prefs;
    NSDictionary *_connectivityRowOrderDictionary;
}

@property (nonatomic, strong) NSDictionary *prefs;
@property (nonatomic, strong) NSDictionary *connectivityRowOrderDictionary;

+ (instancetype)sharedSettings;
- (void)load;
- (void)updateAkaraWithNotification:(NSNotification *)notification;

@property (nonatomic, readonly) BOOL tweakEnabled;
@property (nonatomic, readonly) BOOL optionEnabled;

@property (nonatomic, readonly) BOOL useLargeMode;
@property (nonatomic, readonly) BOOL useSEMode;
@property (nonatomic, readonly) BOOL useBackgroundBlur;
@property (nonatomic, readonly) BOOL useBackgroundImage;
@property (nonatomic, readonly) BOOL useCustomCornerRadius;
@property (nonatomic, readonly) BOOL useCustomMaterialViewAlpha;
@property (nonatomic, readonly) BOOL useStaticWifiIcon;
@property (nonatomic, readonly) BOOL useStaticBluetoothIcon;
@property (nonatomic, readonly) BOOL useStaticBrightnessSliderIcon;
@property (nonatomic, readonly) BOOL useStaticVolumeSliderIcon;
@property (nonatomic, readonly) BOOL useNativeConnectivityLabels;
@property (nonatomic, readonly) BOOL showMediaRadioButton;
@property (nonatomic, readonly) BOOL showStatusBar;
@property (nonatomic, readonly) BOOL showNotchAndNormalStatusBar;
@property (nonatomic, readonly) BOOL enableTopRightGesture;
@property (nonatomic, readonly) BOOL enableTopRightAndBottomGesture;
@property (nonatomic, readonly) BOOL easeLockScreenGesture;
@property (nonatomic, readonly) BOOL extraDisableInLandscape;
@property (nonatomic, readonly) BOOL scrollBackToFirstConnectivityPage;
@property (nonatomic, readonly) BOOL akaraCCDismiss;
@property (nonatomic, readonly) BOOL animateTopConstraintAsNecessary;

@property (nonatomic, readonly) NSInteger backgroundBlurStyle;
@property (nonatomic, readonly) CGFloat customCornerRadius;
@property (nonatomic, readonly) CGFloat customMaterialViewAlpha;
@property (nonatomic, readonly) CGFloat customMediaHeight;
@property (nonatomic, readonly) CGFloat customMediaWidth;
@property (nonatomic, readonly) CGFloat customSliderHeight;

@property (nonatomic, readonly) NSString *connectivityFirstRowOrder;
@property (nonatomic, readonly) NSString *connectivitySecondRowOrder;

@property (nonatomic, readonly, nullable) NSString *akBackgroundImage;
@property (nonatomic, readonly, nullable) UIImage *akBackgroundImageView;
@property (nonatomic, readonly) NSInteger blurOption;

- (void)dismissAkara:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
