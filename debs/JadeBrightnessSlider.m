// JadeBrightnessSlider.m
// Custom brightness slider for the Jade control center
// Implements a UIControl-based brightness slider with custom track, thumb, and icons

#import "JadeBrightnessSlider.h"
#import <UIKit/UIKit.h>

@interface JadeBrightnessSlider ()

// Internal ivars from binary analysis
@property (nonatomic, strong, nullable) id brightnessController;
@property (nonatomic, strong, nullable) UIImage *icon;
@property (nonatomic, strong, nullable) UIView *customBackground;
@property (nonatomic, strong, nullable) UILabel *progressLabel;
@property (nonatomic, assign) double deltaTime;
@property (nonatomic, strong, nullable) UIImage *brightnessMinImage;
@property (nonatomic, strong, nullable) UIImage *brightnessMaxImage;

@property (nonatomic, strong) UIImpactFeedbackGenerator *hapticGenerator;
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) float pendingValue;

- (void)setSystemBrightnessLevel:(float)level animated:(BOOL)animated;

@end

@implementation JadeBrightnessSlider

@synthesize deltaTime = _deltaTime;

#pragma mark - Initialization

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _minimumValue = 0.0f;
        _maximumValue = 1.0f;
        _value = [UIScreen mainScreen].brightness;
        _sliderHeight = 32.0f;
        _cornerRadius = 8.0f;
        _continuous = YES;
        _isDragging = NO;
        _pendingValue = _value;
        _deltaTime = 0.0;

        // Create brightness controller without requiring SpringBoard private SDK headers.
        Class brightnessControllerClass = NSClassFromString(@"SBDisplayBrightnessController");
        if (brightnessControllerClass) {
            _brightnessController = [[brightnessControllerClass alloc] init];
        }

        // Create SF Symbol images
        _brightnessMinImage = [UIImage systemImageNamed:@"sun.min.fill"];
        _brightnessMaxImage = [UIImage systemImageNamed:@"sun.max.fill"];

        // Haptic generator
        _hapticGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

        // Setup UI
        [self setupViews];
        [self setupConstraints];
        [self updateSliderAppearance];
        [self updateSliderValue];

        // Observe brightness changes
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(updateSliderValue)
                                                     name:UIScreenBrightnessDidChangeNotification
                                                   object:nil];
    }
    return self;
}

#pragma mark - Setup Views

- (void)setupViews {
    // Create background view
    _customBackground = [[UIView alloc] initWithFrame:CGRectZero];
    _customBackground.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    _customBackground.layer.cornerRadius = _cornerRadius;
    _customBackground.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_customBackground];

    // Create icon image view
    _iconImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    _iconImageView.image = _brightnessMinImage ?: [UIImage systemImageNamed:@"sun.min.fill"];
    _iconImageView.tintColor = [UIColor whiteColor];
    _iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_iconImageView];

    // Create the internal UISlider
    _slider = [[UISlider alloc] initWithFrame:CGRectZero];
    _slider.minimumValue = _minimumValue;
    _slider.maximumValue = _maximumValue;
    _slider.value = _value;
    _slider.continuous = YES;
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    [_slider addTarget:self action:@selector(sliderValueDidChange:) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self action:@selector(sliderTouchDown:) forControlEvents:UIControlEventTouchDown];
    [_slider addTarget:self action:@selector(sliderTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self addSubview:_slider];

    // Create custom track view
    _trackView = [[UIView alloc] initWithFrame:CGRectZero];
    _trackView.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    _trackView.layer.cornerRadius = _cornerRadius;
    _trackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self insertSubview:_trackView belowSubview:_slider];

    // Create custom progress view
    _progressView = [[UIView alloc] initWithFrame:CGRectZero];
    _progressView.backgroundColor = _progressColor ?: [UIColor systemYellowColor];
    _progressView.layer.cornerRadius = _cornerRadius;
    _progressView.translatesAutoresizingMaskIntoConstraints = NO;
    [self insertSubview:_progressView belowSubview:_slider];

    // Create thumb view
    _thumbView = [[UIView alloc] initWithFrame:CGRectZero];
    _thumbView.backgroundColor = _thumbColor ?: [UIColor whiteColor];
    _thumbView.layer.cornerRadius = 8.0f;
    _thumbView.translatesAutoresizingMaskIntoConstraints = NO;
    _thumbView.userInteractionEnabled = NO;
    [self addSubview:_thumbView];

    // Create progress label
    _progressLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _progressLabel.textAlignment = NSTextAlignmentCenter;
    _progressLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    _progressLabel.textColor = [UIColor whiteColor];
    _progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _progressLabel.alpha = 0.0f;
    [self addSubview:_progressLabel];

    // Pan gesture for fine control
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:panGesture];

    // Long press gesture to set to 50%
    UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPressGesture.minimumPressDuration = 0.5;
    [self addGestureRecognizer:longPressGesture];
}

- (void)setupConstraints {
    NSLayoutConstraint *heightConstraint = [self.heightAnchor constraintEqualToConstant:62];
    heightConstraint.priority = UILayoutPriorityRequired - 1;

    [NSLayoutConstraint activateConstraints:@[
        // Self height
        heightConstraint,

        // Custom background
        [_customBackground.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
        [_customBackground.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        [_customBackground.topAnchor constraintEqualToAnchor:self.topAnchor constant:2],
        [_customBackground.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-2],

        // Icon image view (leading)
        [_iconImageView.leadingAnchor constraintEqualToAnchor:_customBackground.leadingAnchor constant:12],
        [_iconImageView.centerYAnchor constraintEqualToAnchor:_customBackground.centerYAnchor],
        [_iconImageView.widthAnchor constraintEqualToConstant:20],
        [_iconImageView.heightAnchor constraintEqualToConstant:20],

        // Slider
        [_slider.leadingAnchor constraintEqualToAnchor:_iconImageView.trailingAnchor constant:10],
        [_slider.trailingAnchor constraintEqualToAnchor:_customBackground.trailingAnchor constant:-12],
        [_slider.centerYAnchor constraintEqualToAnchor:_customBackground.centerYAnchor],
        [_slider.heightAnchor constraintEqualToConstant:_sliderHeight],

        // Progress label (centered on slider)
        [_progressLabel.centerXAnchor constraintEqualToAnchor:_slider.centerXAnchor],
        [_progressLabel.centerYAnchor constraintEqualToAnchor:_slider.centerYAnchor],
    ]];

    // Track view constraints (behind slider)
    [NSLayoutConstraint activateConstraints:@[
        [_trackView.leadingAnchor constraintEqualToAnchor:_slider.leadingAnchor],
        [_trackView.trailingAnchor constraintEqualToAnchor:_slider.trailingAnchor],
        [_trackView.centerYAnchor constraintEqualToAnchor:_slider.centerYAnchor],
        [_trackView.heightAnchor constraintEqualToConstant:6],
    ]];

    // Progress view constraints
    [NSLayoutConstraint activateConstraints:@[
        [_progressView.leadingAnchor constraintEqualToAnchor:_trackView.leadingAnchor],
        [_progressView.centerYAnchor constraintEqualToAnchor:_trackView.centerYAnchor],
        [_progressView.heightAnchor constraintEqualToAnchor:_trackView.heightAnchor],
    ]];

    // Progress view width will be updated in layoutSubviews
    // Thumb view will be positioned in layoutSubviews
}

- (void)layoutSubviews {
    [super layoutSubviews];

    // Update progress view width based on current value
    if (_slider && _trackView) {
        CGFloat trackWidth = _trackView.bounds.size.width;
        if (trackWidth > 0) {
            float normalizedValue = (_value - _minimumValue) / (_maximumValue - _minimumValue);
            CGRect progressFrame = _progressView.frame;
            progressFrame.size.width = trackWidth * normalizedValue;
            _progressView.frame = progressFrame;
        }
    }

    // Position thumb view
    if (_slider && _thumbView) {
        CGFloat trackWidth = _slider.bounds.size.width;
        if (trackWidth > 0) {
            float normalizedValue = (_value - _minimumValue) / (_maximumValue - _minimumValue);
            CGFloat thumbX = _slider.frame.origin.x + (trackWidth * normalizedValue) - 8;
            _thumbView.frame = CGRectMake(thumbX, _slider.center.y - 8, 16, 16);
            _thumbView.layer.cornerRadius = 8;
        }
    }
}

#pragma mark - Track Image Creation

- (UIImage *)trackImageWithHeight:(CGFloat)height color:(UIColor *)color {
    CGSize size = CGSizeMake(1, height);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    [color setFill];
    UIBezierPath *roundedRect = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 1, height)
                                                          cornerRadius:height / 2.0];
    [roundedRect fill];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsZero];
}

#pragma mark - Appearance

- (void)updateSliderAppearance {
    // Read preferences
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jadeprefs"];

    UIColor *bgColor = nil;
    NSString *bgColorHex = [prefs stringForKey:@"brightnessBackgroundColor"];
    if (bgColorHex) {
        bgColor = [self colorFromHexString:bgColorHex];
    }
    if (!bgColor) {
        bgColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    }
    _customBackground.backgroundColor = bgColor;

    UIColor *sliderColor = nil;
    NSString *sliderColorHex = [prefs stringForKey:@"brightnessSliderColor"];
    if (sliderColorHex) {
        sliderColor = [self colorFromHexString:sliderColorHex];
    }
    if (!sliderColor) {
        sliderColor = [UIColor systemYellowColor];
    }
    _progressColor = sliderColor;
    _progressView.backgroundColor = sliderColor;

    // Configure slider appearance
    UIImage *minTrackImage = [self trackImageWithHeight:6 color:sliderColor];
    UIImage *maxTrackImage = [self trackImageWithHeight:6 color:[UIColor colorWithWhite:0.25 alpha:1.0]];
    [_slider setMinimumTrackImage:minTrackImage forState:UIControlStateNormal];
    [_slider setMaximumTrackImage:maxTrackImage forState:UIControlStateNormal];
    [_slider setThumbImage:[UIImage new] forState:UIControlStateNormal];

    // Update icons based on preferences
    BOOL staticGlyphs = [prefs boolForKey:@"staticGlyphs"];
    BOOL percentLabels = [prefs boolForKey:@"percentLabels"];

    if (!staticGlyphs) {
        _iconImageView.image = _brightnessMinImage ?: [UIImage systemImageNamed:@"sun.min.fill"];
    } else {
        _iconImageView.image = [UIImage systemImageNamed:@"sun.min.fill"];
    }

    _progressLabel.hidden = !percentLabels;

    // Corner radius
    BOOL roundedSliders = [prefs boolForKey:@"roundedSliders"];
    _cornerRadius = roundedSliders ? 12.0f : 8.0f;
    _customBackground.layer.cornerRadius = _cornerRadius;

    // Haptic flag is read at runtime in sliderValueDidChange
}

#pragma mark - Value Changes

- (void)setSystemBrightnessLevel:(float)level animated:(BOOL)animated {
    float clampedLevel = MAX(_minimumValue, MIN(_maximumValue, level));
    SEL setBrightnessSelector = @selector(setBrightnessLevel:animated:);
    if ([_brightnessController respondsToSelector:setBrightnessSelector]) {
        void (*setBrightness)(id, SEL, float, BOOL) = (void (*)(id, SEL, float, BOOL))[_brightnessController methodForSelector:setBrightnessSelector];
        setBrightness(_brightnessController, setBrightnessSelector, clampedLevel, animated);
    } else {
        [UIScreen mainScreen].brightness = clampedLevel;
    }
}

- (void)sliderValueDidChange:(UISlider *)sender {
    float newValue = sender.value;
    _value = newValue;

    // Update brightness controller
    [self setSystemBrightnessLevel:newValue animated:YES];

    // Update progress label
    int percentage = (int)roundf(newValue * 100.0f);
    _progressLabel.text = [NSString stringWithFormat:@"%d%%", percentage];

    // Show progress label temporarily
    [self showProgressLabelAnimated];

    // Update progress and thumb positions
    [self setNeedsLayout];

    // Haptic feedback
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jadeprefs"];
    BOOL hapticSliders = [prefs boolForKey:@"hapticSliders"];
    if (hapticSliders) {
        [_hapticGenerator impactOccurred];
    }

    // Send actions
    if (self.continuous) {
        [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
}

- (void)sliderTouchDown:(UISlider *)sender {
    _isDragging = YES;

    // Show progress label
    [UIView animateWithDuration:0.2 animations:^{
        self->_progressLabel.alpha = 1.0f;
    }];

    [_hapticGenerator prepare];
}

- (void)sliderTouchUp:(UISlider *)sender {
    _isDragging = NO;

    // Hide progress label after delay
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_isDragging) {
            [UIView animateWithDuration:0.3 animations:^{
                self->_progressLabel.alpha = 0.0f;
            }];
        }
    });

    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)updateSliderValue {
    float screenBrightness = [UIScreen mainScreen].brightness;
    _value = screenBrightness;
    _slider.value = screenBrightness;
    [self setNeedsLayout];

    int percentage = (int)roundf(screenBrightness * 100.0f);
    _progressLabel.text = [NSString stringWithFormat:@"%d%%", percentage];
}

#pragma mark - Gesture Handlers

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    CGFloat sensitivity = 0.003;
    float delta = translation.x * sensitivity;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        _isDragging = YES;
        _pendingValue = _value;
        [_hapticGenerator prepare];
        [UIView animateWithDuration:0.2 animations:^{
            self->_progressLabel.alpha = 1.0f;
        }];
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        _pendingValue = MAX(_minimumValue, MIN(_maximumValue, _pendingValue + delta));
        _value = _pendingValue;
        _slider.value = _pendingValue;
        [self setSystemBrightnessLevel:_pendingValue animated:NO];
        [self setNeedsLayout];

        int percentage = (int)roundf(_pendingValue * 100.0f);
        _progressLabel.text = [NSString stringWithFormat:@"%d%%", percentage];

        [gesture setTranslation:CGPointZero inView:self];
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        _isDragging = NO;
        [self sendActionsForControlEvents:UIControlEventValueChanged];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self->_isDragging) {
                [UIView animateWithDuration:0.3 animations:^{
                    self->_progressLabel.alpha = 0.0f;
                }];
            }
        });
    } else {
        _isDragging = NO;
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        float midValue = (_maximumValue - _minimumValue) / 2.0f;
        _value = midValue;
        _slider.value = midValue;
        [self setSystemBrightnessLevel:midValue animated:YES];
        [self setNeedsLayout];

        int percentage = (int)roundf(midValue * 100.0f);
        _progressLabel.text = [NSString stringWithFormat:@"%d%%", percentage];

        [UIView animateWithDuration:0.2 animations:^{
            self->_progressLabel.alpha = 1.0f;
        }];

        [_hapticGenerator impactOccurred];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                self->_progressLabel.alpha = 0.0f;
            }];
        });
    }
}

#pragma mark - Public Methods

- (void)setValue:(float)value {
    [self setValue:value animated:NO];
}

- (void)setValue:(float)value animated:(BOOL)animated {
    _value = MAX(_minimumValue, MIN(_maximumValue, value));
    _slider.value = _value;

    if (animated) {
        [UIView animateWithDuration:0.25 animations:^{
            [self layoutIfNeeded];
        }];
    } else {
        [self setNeedsLayout];
    }

    int percentage = (int)roundf(_value * 100.0f);
    _progressLabel.text = [NSString stringWithFormat:@"%d%%", percentage];
}

- (void)setIcon:(UIImage *)icon {
    _icon = icon;
    _iconImageView.image = icon;
}

- (void)setMinimumValue:(float)minimumValue {
    _minimumValue = minimumValue;
    _slider.minimumValue = minimumValue;
}

- (void)setMaximumValue:(float)maximumValue {
    _maximumValue = maximumValue;
    _slider.maximumValue = maximumValue;
}

- (void)setSliderHeight:(CGFloat)sliderHeight {
    _sliderHeight = sliderHeight;
    [self setNeedsLayout];
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    _customBackground.layer.cornerRadius = cornerRadius;
    _trackView.layer.cornerRadius = cornerRadius;
    _progressView.layer.cornerRadius = cornerRadius;
}

- (void)beginTrackingInteraction {
    _isDragging = YES;
    [UIView animateWithDuration:0.2 animations:^{
        self->_progressLabel.alpha = 1.0f;
    }];
}

- (void)endTrackingInteraction {
    _isDragging = NO;
    [UIView animateWithDuration:0.3 animations:^{
        self->_progressLabel.alpha = 0.0f;
    }];
}

#pragma mark - Helper Methods

- (void)showProgressLabelAnimated {
    [UIView animateWithDuration:0.15 animations:^{
        self->_progressLabel.alpha = 1.0f;
    }];

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideProgressLabel) object:nil];
    [self performSelector:@selector(hideProgressLabel) withObject:nil afterDelay:1.0];
}

- (void)hideProgressLabel {
    if (!_isDragging) {
        [UIView animateWithDuration:0.3 animations:^{
            self->_progressLabel.alpha = 0.0f;
        }];
    }
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    NSString *cleaned = [[hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([cleaned hasPrefix:@"#"]) {
        cleaned = [cleaned substringFromIndex:1];
    }
    if ([cleaned length] < 6) {
        return nil;
    }

    unsigned int rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:cleaned];
    [scanner scanHexInt:&rgbValue];

    CGFloat alpha = 1.0f;
    if ([cleaned length] >= 8) {
        alpha = ((rgbValue >> 24) & 0xFF) / 255.0f;
    }

    return [UIColor colorWithRed:((rgbValue >> 16) & 0xFF) / 255.0f
                           green:((rgbValue >> 8) & 0xFF) / 255.0f
                            blue:(rgbValue & 0xFF) / 255.0f
                           alpha:alpha];
}

#pragma mark - Dealloc

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIScreenBrightnessDidChangeNotification object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

@end
