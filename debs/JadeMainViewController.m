// JadeMainViewController.m
// Main view controller for the Jade control center overlay

#import "JadeMainViewController.h"
#import "JadeCardViewController.h"
#import "JadeBatteryPill.h"
#import "JadeTimePill.h"

// Preferences
static NSString *const kJadePrefsSuite = @"com.huayuarc.jadeprefs";
static NSString *const kJadePortraitOffsetKey = @"portraitPresentationOffset";
static NSString *const kJadeLandscapeOffsetKey = @"landscapePresentationOffset";

static UIInterfaceOrientation JadeCurrentInterfaceOrientation(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateForegroundActive ||
                windowScene.activationState == UISceneActivationStateForegroundInactive) {
                return windowScene.interfaceOrientation;
            }
        }
    }

    return UIInterfaceOrientationPortrait;
}

@interface JadeMainViewController () <UIScrollViewDelegate>

@property (nonatomic, strong) UIPanGestureRecognizer *panGestureRecognizer;
@property (nonatomic, strong) UIButton *dismissButton;
@property (nonatomic, assign) CGFloat portraitPresentationOffset;
@property (nonatomic, assign) CGFloat landscapePresentationOffset;

- (void)_updateOffsets;

@end

@implementation JadeMainViewController {
    JadeCardViewController *_cardViewController;
}

@synthesize cardViewController = _cardViewController;

#pragma mark - Initialization

- (instancetype)initWithCardViewController:(JadeCardViewController *)cardVC {
    self = [super init];
    if (self) {
        _cardViewController = cardVC;
        _isPresented = NO;
        _isAnimating = NO;
        _presentationProgress = 0.0;
        _portraitPresentationOffset = 0.0;
        _landscapePresentationOffset = 0.0;
    }
    return self;
}

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        _isPresented = NO;
        _isAnimating = NO;
        _presentationProgress = 0.0;
    }
    return self;
}

#pragma mark - View Lifecycle (Binary Methods)

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    view.backgroundColor = [UIColor blackColor];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // Add tap-to-dismiss gesture
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(singleTap)];
    tapGesture.numberOfTapsRequired = 1;
    [view addGestureRecognizer:tapGesture];

    // Add blur effect
    UIVisualEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.frame = view.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurView.alpha = 0.85;
    [view addSubview:blurView];
    self.blurView = blurView;

    // Content container
    UIView *container = [[UIView alloc] initWithFrame:view.bounds];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [view addSubview:container];
    self.contentContainer = container;

    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    if (_cardViewController) {
        [self addChildViewController:_cardViewController];
        _cardViewController.view.frame = self.contentContainer.bounds;
        _cardViewController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.contentContainer addSubview:_cardViewController.view];
        [_cardViewController didMoveToParentViewController:self];
    }

    // Read offset preferences
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kJadePrefsSuite];
    _portraitPresentationOffset = [prefs floatForKey:kJadePortraitOffsetKey];
    _landscapePresentationOffset = [prefs floatForKey:kJadeLandscapeOffsetKey];

    [self _updateOffsets];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self _updateOffsets];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
}

#pragma mark - Lock Screen Support

- (BOOL)_canShowWhileLocked {
    return YES;
}

#pragma mark - Orientation / Presentation Offsets

- (void)_updateOffsets {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kJadePrefsSuite];
    _portraitPresentationOffset = [prefs floatForKey:kJadePortraitOffsetKey];
    _landscapePresentationOffset = [prefs floatForKey:kJadeLandscapeOffsetKey];

    UIInterfaceOrientation orientation = JadeCurrentInterfaceOrientation();
    CGFloat offset = 0.0;

    if (UIInterfaceOrientationIsLandscape(orientation)) {
        offset = _landscapePresentationOffset;
    } else {
        offset = _portraitPresentationOffset;
    }

    // Adjust card position based on offset
    CGRect cardFrame = _cardViewController.view.frame;
    cardFrame.origin.y = offset;
    _cardViewController.view.frame = cardFrame;
}

#pragma mark - Gesture Actions

- (void)singleTap {
    [self dismissAnimated:YES completion:nil];
}

#pragma mark - Presentation Methods

- (void)presentAnimated:(BOOL)animated completion:(void (^)(void))completion {
    if (_isPresented) {
        if (completion) completion();
        return;
    }

    _isAnimating = YES;

    if (animated) {
        self.view.alpha = 0.0;
        self.view.transform = CGAffineTransformMakeScale(0.95, 0.95);

        [UIView animateWithDuration:0.35
                              delay:0.0
             usingSpringWithDamping:1.0
              initialSpringVelocity:0.0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.view.alpha = 1.0;
            self.view.transform = CGAffineTransformIdentity;
        } completion:^(BOOL finished) {
            _isPresented = YES;
            _isAnimating = NO;
            _presentationProgress = 1.0;
            if (completion) completion();
        }];
    } else {
        self.view.alpha = 1.0;
        _isPresented = YES;
        _isAnimating = NO;
        _presentationProgress = 1.0;
        if (completion) completion();
    }
}

- (void)dismissAnimated:(BOOL)animated completion:(void (^)(void))completion {
    if (!_isPresented) {
        if (completion) completion();
        return;
    }

    _isAnimating = YES;

    if (animated) {
        [UIView animateWithDuration:0.25
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            self.view.alpha = 0.0;
            self.view.transform = CGAffineTransformMakeScale(0.95, 0.95);
        } completion:^(BOOL finished) {
            _isPresented = NO;
            _isAnimating = NO;
            _presentationProgress = 0.0;
            if (completion) completion();
        }];
    } else {
        self.view.alpha = 0.0;
        _isPresented = NO;
        _isAnimating = NO;
        _presentationProgress = 0.0;
        if (completion) completion();
    }
}

- (void)updatePresentationProgress:(CGFloat)progress {
    _presentationProgress = progress;
    self.view.alpha = progress;
    CGFloat scale = 0.95 + (0.05 * progress);
    self.view.transform = CGAffineTransformMakeScale(scale, scale);
}

#pragma mark - Status Bar

- (BOOL)prefersStatusBarHidden {
    return YES;
}

#pragma mark - View Setup

- (void)setupViews {
    // Called externally to configure initial view hierarchy
    [self loadView];
    [self viewDidLoad];
}

- (void)setupConstraints {
    // Layout constraints for all subviews
    if (_cardViewController) {
        _cardViewController.view.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [_cardViewController.view.centerXAnchor constraintEqualToAnchor:self.contentContainer.centerXAnchor],
            [_cardViewController.view.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
            [_cardViewController.view.widthAnchor constraintEqualToAnchor:self.contentContainer.widthAnchor multiplier:0.9],
            [_cardViewController.view.heightAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.heightAnchor multiplier:0.85]
        ]];
    }
}

#pragma mark - Appearance

- (void)applyCornerRadius:(CGFloat)radius {
    if (_cardViewController) {
        _cardViewController.view.layer.cornerRadius = radius;
        _cardViewController.view.clipsToBounds = YES;
    }
}

#pragma mark - Gesture Handling

- (void)handlePanGesture:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.view];
    CGPoint velocity = [gesture velocityInView:self.view];

    switch (gesture.state) {
        case UIGestureRecognizerStateChanged: {
            CGFloat progress = translation.y / CGRectGetHeight(self.view.bounds);
            progress = MAX(0.0, MIN(1.0, progress));
            [self updatePresentationProgress:1.0 - progress];
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (velocity.y > 500 || translation.y > CGRectGetHeight(self.view.bounds) * 0.3) {
                [self dismissAnimated:YES completion:nil];
            } else {
                [UIView animateWithDuration:0.3 animations:^{
                    self.view.alpha = 1.0;
                    self.view.transform = CGAffineTransformIdentity;
                } completion:^(BOOL finished) {
                    _presentationProgress = 1.0;
                }];
            }
            break;
        }
        default:
            break;
    }
}

@end
