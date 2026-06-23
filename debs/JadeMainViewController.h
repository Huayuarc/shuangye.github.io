// JadeMainViewController.h
// Main view controller for the Jade control center overlay

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class JadeCardViewController;
@class JadeWeatherHandler;
@class JadeBatteryPill;
@class JadeTimePill;

@interface JadeMainViewController : UIViewController

@property (nonatomic, strong, nullable) JadeCardViewController *cardViewController;
@property (nonatomic, strong, nullable) UIView *backgroundView;
@property (nonatomic, strong, nullable) UIVisualEffectView *blurView;
@property (nonatomic, strong, nullable) UIView *contentContainer;
@property (nonatomic, strong, nullable) JadeBatteryPill *batteryPill;
@property (nonatomic, strong, nullable) JadeTimePill *timePill;
@property (nonatomic, assign) BOOL isPresented;
@property (nonatomic, assign) BOOL isAnimating;
@property (nonatomic, assign) CGFloat presentationProgress;

- (instancetype)initWithCardViewController:(JadeCardViewController *)cardVC;
- (void)presentAnimated:(BOOL)animated completion:(void (^ _Nullable)(void))completion;
- (void)dismissAnimated:(BOOL)animated completion:(void (^ _Nullable)(void))completion;
- (void)updatePresentationProgress:(CGFloat)progress;
- (void)setupViews;
- (void)setupConstraints;
- (void)applyCornerRadius:(CGFloat)radius;
- (void)handlePanGesture:(UIPanGestureRecognizer *)gesture;

@end

NS_ASSUME_NONNULL_END
