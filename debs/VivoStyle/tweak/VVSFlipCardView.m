#import "VVSFlipCardView.h"
#import "../common/VVSCommon.h"
#import <CoreMotion/CoreMotion.h>

// How many degrees of left/right tilt span the *entire* image set at the
// minimum sensitivity. Sensitivity scales this down so a higher value means
// a smaller required tilt.
static const CGFloat kVVSMaxTiltDegrees = 55.0;

// Extra size given to each image beyond the view bounds so that the parallax
// translation never exposes an empty edge.
static const CGFloat kVVSOverscan = 60.0;

@interface VVSFlipCardView ()
@property (nonatomic, strong) NSMutableArray<UIView *> *slides;          // one container per image
@property (nonatomic, strong) NSMutableArray<UIImageView *> *foregrounds; // parallax targets (parallel to slides)
@property (nonatomic, strong) CMMotionManager *motionManager;
@property (nonatomic, strong) NSOperationQueue *motionQueue;

@property (nonatomic, assign) CGFloat smoothedPosition;   // 0 .. count-1
@property (nonatomic, assign) BOOL hasSmoothed;

// tunables
@property (nonatomic, assign) CGFloat sensitivity;        // 0..1
@property (nonatomic, assign) CGFloat parallaxStrength;   // 0..1
@property (nonatomic, assign) CGFloat smoothing;          // 0..1
@property (nonatomic, assign) BOOL loop;
@property (nonatomic, assign) BOOL fill;                  // YES = crop-to-fill, NO = fit whole photo
@property (nonatomic, assign) NSInteger transition;      // 0=fade 1=lenticular 2=frosted 3=depth

// Effect helpers
@property (nonatomic, strong) UIVisualEffectView *glassView;   // frosted-glass overlay
@property (nonatomic, strong) CAReplicatorLayer *lenticularMask;
@property (nonatomic, strong) CALayer *lenticularBar;
@end

@implementation VVSFlipCardView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;       // never steal touches from the lock screen
        self.backgroundColor = [UIColor blackColor];
        self.slides = [NSMutableArray array];
        self.foregrounds = [NSMutableArray array];
        self.motionQueue = [[NSOperationQueue alloc] init];
        self.motionQueue.name = @"com.vivostyle.motion";
        self.motionQueue.maxConcurrentOperationCount = 1;
        [self reloadFromPreferences];
    }
    return self;
}

- (BOOL)hasContent {
    return self.slides.count > 0;
}

#pragma mark - Preferences / image loading

- (void)reloadFromPreferences {
    CFPreferencesAppSynchronize(kVVSPrefsAppID);

    self.sensitivity      = [self prefFloat:kVVSKeySensitivity defaultValue:0.5];
    self.parallaxStrength = [self prefFloat:kVVSKeyParallax    defaultValue:0.6];
    self.smoothing        = [self prefFloat:kVVSKeySmoothing   defaultValue:0.5];
    self.loop             = [self prefBool:kVVSKeyLoop         defaultValue:NO];
    self.fill             = [self prefBool:kVVSKeyFill         defaultValue:NO];
    self.transition       = [self prefInteger:kVVSKeyTransition defaultValue:0];

    // Tear down the old stack.
    for (UIView *s in self.slides) [s removeFromSuperview];
    [self.slides removeAllObjects];
    [self.foregrounds removeAllObjects];

    NSInteger count = [self prefInteger:kVVSKeyImageCount defaultValue:0];
    for (NSInteger i = 0; i < count; i++) {
        NSString *path = VVSImagePathAtIndex(i);
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        if (!img) continue;
        UIImageView *fg = nil;
        UIView *slide = [self makeSlideForImage:img foreground:&fg];
        slide.alpha = (self.slides.count == 0) ? 1.0 : 0.0;
        [self addSubview:slide];
        [self.slides addObject:slide];
        [self.foregrounds addObject:fg];
    }

    self.hasSmoothed = NO;
    [self setNeedsLayout];
    [self layoutImageViews];
}

// Builds a container holding (for "fit" mode) a blurred full-bleed backdrop
// plus a centered, fully-visible photo; or (for "fill" mode) a single
// crop-to-fill photo. `*outForeground` is the view we parallax.
- (UIView *)makeSlideForImage:(UIImage *)img foreground:(UIImageView **)outForeground {
    UIView *c = [[UIView alloc] initWithFrame:self.bounds];
    c.clipsToBounds = YES;
    c.backgroundColor = [UIColor blackColor];

    if (self.fill) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:img];
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        [c addSubview:iv];
        if (outForeground) *outForeground = iv;
    } else {
        // Blurred backdrop fills the screen so there are no empty bars.
        UIImageView *bg = [[UIImageView alloc] initWithImage:img];
        bg.contentMode = UIViewContentModeScaleAspectFill;
        bg.clipsToBounds = YES;
        bg.tag = 100;
        [c addSubview:bg];

        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
        blur.tag = 101;
        [c addSubview:blur];

        // Sharp, fully-visible photo, centered, height-fit.
        UIImageView *fg = [[UIImageView alloc] initWithImage:img];
        fg.contentMode = UIViewContentModeScaleAspectFit;
        fg.clipsToBounds = NO;
        [c addSubview:fg];
        if (outForeground) *outForeground = fg;
    }
    return c;
}

- (CGFloat)prefFloat:(NSString *)key defaultValue:(CGFloat)def {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, kVVSPrefsAppID);
    CGFloat r = def;
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) { double d; CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &d); r = d; }
        CFRelease(v);
    }
    return r;
}
- (NSInteger)prefInteger:(NSString *)key defaultValue:(NSInteger)def {
    Boolean ok = false;
    CFIndex v = CFPreferencesGetAppIntegerValue((__bridge CFStringRef)key, kVVSPrefsAppID, &ok);
    return ok ? (NSInteger)v : def;
}
- (BOOL)prefBool:(NSString *)key defaultValue:(BOOL)def {
    Boolean ok = false;
    Boolean v = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key, kVVSPrefsAppID, &ok);
    return ok ? (BOOL)v : def;
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutImageViews];
}

- (void)layoutImageViews {
    for (NSInteger i = 0; i < (NSInteger)self.slides.count; i++) {
        UIView *slide = self.slides[i];
        slide.frame = self.bounds;

        UIImageView *fg = self.foregrounds[i];
        fg.transform = CGAffineTransformIdentity;
        if (self.fill) {
            // Oversize so parallax never reveals an edge.
            fg.frame = CGRectInset(self.bounds, -kVVSOverscan, -kVVSOverscan);
        } else {
            fg.frame = self.bounds;               // AspectFit centers within
            UIView *bg = [slide viewWithTag:100];
            UIView *blur = [slide viewWithTag:101];
            bg.frame = CGRectInset(self.bounds, -kVVSOverscan, -kVVSOverscan);
            blur.frame = self.bounds;
        }
    }
}

#pragma mark - Motion

- (void)startMotion {
    if (!self.hasContent) return;
    if (!self.motionManager) {
        self.motionManager = [[CMMotionManager alloc] init];
        self.motionManager.deviceMotionUpdateInterval = 1.0 / 60.0;
    }
    if (self.motionManager.isDeviceMotionActive) return;
    if (!self.motionManager.isDeviceMotionAvailable) return;

    __weak typeof(self) weakSelf = self;
    [self.motionManager startDeviceMotionUpdatesToQueue:self.motionQueue
                                            withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (!motion) return;
        CGFloat gx = motion.gravity.x;
        CGFloat gy = motion.gravity.y;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf updateForGravityX:gx y:gy];
        });
    }];
}

- (void)stopMotion {
    if (self.motionManager.isDeviceMotionActive) {
        [self.motionManager stopDeviceMotionUpdates];
    }
    self.hasSmoothed = NO;
}

- (void)updateForGravityX:(CGFloat)gx y:(CGFloat)gy {
    NSInteger n = self.slides.count;
    if (n == 0) return;

    if (n == 1) {
        [self applyParallaxToView:self.foregrounds[0] gx:gx gy:gy];
        return;
    }

    CGFloat tiltDeg = kVVSMaxTiltDegrees * (1.0 - 0.6 * self.sensitivity); // 55deg..22deg
    CGFloat halfSpan = sinf((CGFloat)(tiltDeg * M_PI / 180.0));
    if (halfSpan < 0.05) halfSpan = 0.05;

    CGFloat norm = gx / halfSpan;          // -1 .. 1
    if (norm < -1) norm = -1;
    if (norm > 1)  norm = 1;

    CGFloat target = (norm + 1.0) * 0.5 * (CGFloat)(n - 1);   // 0 .. n-1

    CGFloat alpha = 0.4 - 0.32 * self.smoothing;
    if (!self.hasSmoothed) { self.smoothedPosition = target; self.hasSmoothed = YES; }
    else { self.smoothedPosition += (target - self.smoothedPosition) * alpha; }

    CGFloat pos = self.smoothedPosition;
    NSInteger lower = (NSInteger)floor(pos);
    if (lower < 0) lower = 0;
    if (lower > n - 1) lower = n - 1;
    NSInteger upper = MIN(lower + 1, n - 1);
    CGFloat frac = pos - (CGFloat)lower;
    if (frac < 0) frac = 0;
    if (frac > 1) frac = 1;

    // Reset every slide to a neutral state, then the active transition draws
    // only the two relevant slides.
    for (NSInteger i = 0; i < n; i++) {
        UIView *slide = self.slides[i];
        slide.alpha = 0.0;
        slide.transform = CGAffineTransformIdentity;
        slide.layer.transform = CATransform3DIdentity;
        slide.layer.mask = nil;
    }
    self.glassView.alpha = 0.0;     // frost off unless the frosted effect turns it on

    switch (self.transition) {
        case 1:  [self renderLenticular:lower upper:upper frac:frac gx:gx gy:gy]; break;
        case 2:  [self renderFrosted:lower    upper:upper frac:frac gx:gx gy:gy]; break;
        case 3:  [self renderDepth:lower      upper:upper frac:frac gx:gx gy:gy]; break;
        default: [self renderFade:lower       upper:upper frac:frac gx:gx gy:gy]; break;
    }

    [self bringSubviewToFront:self.slides[lower]];
    if (upper != lower) [self bringSubviewToFront:self.slides[upper]];
    if (self.glassView && self.glassView.alpha > 0.001) [self bringSubviewToFront:self.glassView];
}

// 0 — 渐隐渐显 Cross-fade: dissolve between the two photos.
- (void)renderFade:(NSInteger)lower upper:(NSInteger)upper frac:(CGFloat)frac gx:(CGFloat)gx gy:(CGFloat)gy {
    CGFloat fade = frac * frac * (3.0 - 2.0 * frac);
    self.slides[lower].alpha = 1.0;
    self.slides[upper].alpha = (upper == lower) ? 1.0 : fade;
    [self applyParallaxToView:self.foregrounds[lower] gx:gx gy:gy];
    if (upper != lower) [self applyParallaxToView:self.foregrounds[upper] gx:gx gy:gy];
}

// 1 — 棱镜光栅 Prism Lenticular: the next photo is revealed through growing
//     vertical strips, exactly like tilting a lenticular ("light-grating") card.
- (void)renderLenticular:(NSInteger)lower upper:(NSInteger)upper frac:(CGFloat)frac gx:(CGFloat)gx gy:(CGFloat)gy {
    self.slides[lower].alpha = 1.0;
    [self applyParallaxToView:self.foregrounds[lower] gx:gx gy:gy];
    if (upper == lower) return;

    UIView *up = self.slides[upper];
    up.alpha = 1.0;
    [self applyParallaxToView:self.foregrounds[upper] gx:gx gy:gy];

    // Build/refresh a replicator mask: one growing bar per grating cell.
    const CGFloat cols = 14.0;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat cell = w / cols;
    if (!self.lenticularMask) {
        self.lenticularMask = [CAReplicatorLayer layer];
        self.lenticularBar = [CALayer layer];
        self.lenticularBar.backgroundColor = [UIColor whiteColor].CGColor;
        self.lenticularBar.anchorPoint = CGPointMake(0, 0);
        [self.lenticularMask addSublayer:self.lenticularBar];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.lenticularMask.frame = CGRectMake(0, 0, w, h);
    self.lenticularMask.instanceCount = (NSInteger)cols;
    self.lenticularMask.instanceTransform = CATransform3DMakeTranslation(cell, 0, 0);
    // Bar grows from the centre of each cell so strips open symmetrically.
    CGFloat bw = MAX(0.5, cell * frac);
    self.lenticularBar.frame = CGRectMake((cell - bw) * 0.5, 0, bw, h);
    [CATransaction commit];
    up.layer.mask = self.lenticularMask;
}

// 2 — 磨砂玻璃 Frosted Glass: the two photos cross-fade *through* a pane of
//     frosted glass — the blur peaks mid-transition then clears.
- (void)renderFrosted:(NSInteger)lower upper:(NSInteger)upper frac:(CGFloat)frac gx:(CGFloat)gx gy:(CGFloat)gy {
    CGFloat fade = frac * frac * (3.0 - 2.0 * frac);
    self.slides[lower].alpha = 1.0;
    self.slides[upper].alpha = (upper == lower) ? 1.0 : fade;
    [self applyParallaxToView:self.foregrounds[lower] gx:gx gy:gy];
    if (upper != lower) [self applyParallaxToView:self.foregrounds[upper] gx:gx gy:gy];

    if (!self.glassView) {
        self.glassView = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        self.glassView.userInteractionEnabled = NO;
        [self addSubview:self.glassView];
    }
    self.glassView.frame = self.bounds;
    CGFloat mid = 1.0 - fabs(2.0 * frac - 1.0);     // 0 → 1 → 0
    self.glassView.alpha = mid * 0.97;
}

// 3 — 景深 Depth: a depth-of-field cross-fade — the outgoing photo recedes
//     slightly while the incoming one settles forward into focus.
- (void)renderDepth:(NSInteger)lower upper:(NSInteger)upper frac:(CGFloat)frac gx:(CGFloat)gx gy:(CGFloat)gy {
    CGFloat fade = frac * frac * (3.0 - 2.0 * frac);
    UIView *lo = self.slides[lower];
    lo.alpha = 1.0;
    lo.transform = CGAffineTransformMakeScale(1.0 - 0.06 * frac, 1.0 - 0.06 * frac);
    [self applyParallaxToView:self.foregrounds[lower] gx:gx gy:gy];
    if (upper != lower) {
        UIView *up = self.slides[upper];
        up.alpha = fade;
        CGFloat us = 0.92 + 0.08 * frac;
        up.transform = CGAffineTransformMakeScale(us, us);
        [self applyParallaxToView:self.foregrounds[upper] gx:gx gy:gy];
    }
}

- (void)applyParallaxToView:(UIImageView *)iv gx:(CGFloat)gx gy:(CGFloat)gy {
    CGFloat maxOffset = kVVSOverscan * 0.7 * self.parallaxStrength;
    CGFloat tx = -gx * maxOffset;
    CGFloat ty = -(gy + 1.0) * maxOffset;
    CGFloat lim = kVVSOverscan - 2.0;
    tx = MAX(-lim, MIN(lim, tx));
    ty = MAX(-lim, MIN(lim, ty));
    iv.transform = CGAffineTransformMakeTranslation(tx, ty);
}

@end
