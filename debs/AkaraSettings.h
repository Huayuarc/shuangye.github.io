//
// AkaraSettings.h
// Akara.dylib — Main Tweak Header (Reconstructed)
//
// Reconstructed from: MobileSubstrate/DynamicLibraries/Akara.dylib
// Architecture: arm64 + arm64e (FAT)
// Filter: com.apple.springboard, com.apple.Preferences
//
// This is the ONLY custom ObjC class in the main dylib.
// The tweak also uses C++ functions and dynamic runtime class creation.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AkaraSettings : NSObject
{
    NSDictionary *_prefs;
    NSDictionary *_connectivityRowOrderDictionary;
}

// --- Properties ---
@property (nonatomic, retain) NSDictionary *prefs;
@property (nonatomic, retain) NSDictionary *connectivityRowOrderDictionary;

// --- Singleton ---
+ (instancetype)sharedSettings;

// --- Initialization ---
- (instancetype)init;

// --- Preference Loading / Notifications ---
- (void)load;
- (void)updateAkaraWithNotification:(NSNotification *)notification;

// --- Toggle Switches (BOOL) ---
@property (nonatomic, readonly) BOOL tweakEnabled;
@property (nonatomic, readonly) BOOL optionEnabled;                 // Legacy/alias

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

// --- Integer / Double Values ---
@property (nonatomic, readonly) NSInteger backgroundBlurStyle;
@property (nonatomic, readonly) CGFloat customCornerRadius;
@property (nonatomic, readonly) CGFloat customMaterialViewAlpha;
@property (nonatomic, readonly) CGFloat customMediaHeight;
@property (nonatomic, readonly) CGFloat customMediaWidth;
@property (nonatomic, readonly) CGFloat customSliderHeight;

// --- Connectivity Row Order ---
@property (nonatomic, readonly) NSString *connectivityFirstRowOrder;
@property (nonatomic, readonly) NSString *connectivitySecondRowOrder;

// --- Image / Background Properties ---
@property (nonatomic, readonly, nullable) NSString *akBackgroundImage;
@property (nonatomic, readonly, nullable) UIImage *akBackgroundImageView;
@property (nonatomic, readonly) NSInteger blurOption;

// --- Blur Views (cached) ---
@property (nonatomic, retain, nullable) UIVisualEffectView *blurView;
@property (nonatomic, retain, nullable) UIView *blurBackgroundView;
@property (nonatomic, retain, nullable) NSLayoutConstraint *blurBackgroundViewTopConstraint;

// --- UI Update Methods ---
- (void)updateArtworkAndLabelFrame;
- (void)updateGlyphImage:(nullable id)sender;
- (void)updateSliderGlyphImage;
- (void)updateSliderGlyphImage:(nullable id)sender;
- (void)updateMaterialViewAlpha;
- (void)addBlurViewToBackgroundView;
- (void)controlCenterApplyPrimaryContentShadow;
- (void)launchNowPlayingApp;

// --- Gesture Handlers ---
- (void)handleAKRDismissSwipe:(UISwipeGestureRecognizer *)gesture;
- (void)handleAKRDismissTap:(UITapGestureRecognizer *)gesture;
- (void)handleAKRTopGesture:(UISwipeGestureRecognizer *)gesture;
- (void)dismissAkara:(nullable id)sender;

// --- Setters (non-property) ---
- (void)setAkaraCCDismiss:(BOOL)dismiss;
- (void)setBlurEnabled:(BOOL)enabled;
- (void)setMarqueeEnabled:(BOOL)enabled;
- (void)setMaterialViewVisible:(BOOL)visible;
- (void)setShowRoutingButton:(BOOL)show;

@end

NS_ASSUME_NONNULL_END
