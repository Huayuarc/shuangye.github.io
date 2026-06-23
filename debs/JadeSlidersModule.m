// JadeSlidersModule.m
// Sliders module containing brightness and volume controls
// Arranges brightness and volume sliders in a vertical stack

#import "JadeSlidersModule.h"
#import <UIKit/UIKit.h>

@interface JadeSlidersModule ()

// Internal ivars from binary analysis
@property (nonatomic, strong, nullable) UIStackView *stackView;
@property (nonatomic, assign) BOOL isObservingBrightness;
@property (nonatomic, assign) BOOL isObservingVolume;

@end

@implementation JadeSlidersModule

#pragma mark - Initialization

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _isExpanded = NO;
        _showsLabels = YES;
        _brightnessSliderEnabled = YES;
        _volumeSliderEnabled = YES;
        _isObservingBrightness = NO;
        _isObservingVolume = NO;
        _sliderTintColor = [UIColor whiteColor];
        _sliderTrackColor = [UIColor colorWithWhite:0.25 alpha:1.0];

        [self setupViews];
        [self setupConstraints];

        // Read sliders preferences
        [self updateSliderEnabledStates];

        [self updateBrightnessValue];
        [self updateVolumeValue];
    }
    return self;
}

- (instancetype)init {
    CGRect defaultFrame = CGRectMake(0, 0, 320, 130);
    return [self initWithFrame:defaultFrame];
}

#pragma mark - Preferences

- (void)updateSliderEnabledStates {
    NSUserDefaults *slidersPrefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jade.sliders"];
    _brightnessSliderEnabled = [slidersPrefs boolForKey:@"BRIGHTNESS"];
    _volumeSliderEnabled = [slidersPrefs boolForKey:@"VOLUME"];

    _brightnessSlider.hidden = !_brightnessSliderEnabled;
    _brightnessLabel.hidden = !_brightnessSliderEnabled || !_showsLabels;
    _volumeSlider.hidden = !_volumeSliderEnabled;
    _volumeLabel.hidden = !_volumeSliderEnabled || !_showsLabels;
    _separatorLine.hidden = !(_brightnessSliderEnabled && _volumeSliderEnabled);
}

#pragma mark - Setup Views

- (void)setupViews {
    // Create stack view for vertical arrangement
    _stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stackView.axis = UILayoutConstraintAxisVertical;
    _stackView.distribution = UIStackViewDistributionFillEqually;
    _stackView.alignment = UIStackViewAlignmentFill;
    _stackView.spacing = 2;
    _stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_stackView];

    // Create brightness slider container
    UIView *brightnessContainer = [[UIView alloc] initWithFrame:CGRectZero];
    brightnessContainer.translatesAutoresizingMaskIntoConstraints = NO;

    // Brightness label
    _brightnessLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _brightnessLabel.text = @"Brightness";
    _brightnessLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _brightnessLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    _brightnessLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [brightnessContainer addSubview:_brightnessLabel];

    // Brightness slider
    _brightnessSlider = [[JadeBrightnessSlider alloc] initWithFrame:CGRectZero];
    _brightnessSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [_brightnessSlider addTarget:self action:@selector(brightnessSliderValueChanged:) forControlEvents:UIControlEventValueChanged];
    [brightnessContainer addSubview:_brightnessSlider];

    // Layout brightness container
    [NSLayoutConstraint activateConstraints:@[
        [_brightnessLabel.leadingAnchor constraintEqualToAnchor:brightnessContainer.leadingAnchor constant:8],
        [_brightnessLabel.topAnchor constraintEqualToAnchor:brightnessContainer.topAnchor constant:2],
        [_brightnessLabel.trailingAnchor constraintEqualToAnchor:brightnessContainer.trailingAnchor constant:-8],

        [_brightnessSlider.leadingAnchor constraintEqualToAnchor:brightnessContainer.leadingAnchor],
        [_brightnessSlider.trailingAnchor constraintEqualToAnchor:brightnessContainer.trailingAnchor],
        [_brightnessSlider.topAnchor constraintEqualToAnchor:_brightnessLabel.bottomAnchor constant:2],
        [_brightnessSlider.bottomAnchor constraintEqualToAnchor:brightnessContainer.bottomAnchor constant:-2],
    ]];

    // Separator line
    _separatorLine = [[UIView alloc] initWithFrame:CGRectZero];
    _separatorLine.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    _separatorLine.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_separatorLine];

    // Create volume slider container
    UIView *volumeContainer = [[UIView alloc] initWithFrame:CGRectZero];
    volumeContainer.translatesAutoresizingMaskIntoConstraints = NO;

    // Volume label
    _volumeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _volumeLabel.text = @"Volume";
    _volumeLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _volumeLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    _volumeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [volumeContainer addSubview:_volumeLabel];

    // Volume slider
    _volumeSlider = [[JadeVolumeSlider alloc] initWithFrame:CGRectZero];
    _volumeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [volumeContainer addSubview:_volumeSlider];

    // Layout volume container
    [NSLayoutConstraint activateConstraints:@[
        [_volumeLabel.leadingAnchor constraintEqualToAnchor:volumeContainer.leadingAnchor constant:8],
        [_volumeLabel.topAnchor constraintEqualToAnchor:volumeContainer.topAnchor constant:2],
        [_volumeLabel.trailingAnchor constraintEqualToAnchor:volumeContainer.trailingAnchor constant:-8],

        [_volumeSlider.leadingAnchor constraintEqualToAnchor:volumeContainer.leadingAnchor],
        [_volumeSlider.trailingAnchor constraintEqualToAnchor:volumeContainer.trailingAnchor],
        [_volumeSlider.topAnchor constraintEqualToAnchor:_volumeLabel.bottomAnchor constant:2],
        [_volumeSlider.bottomAnchor constraintEqualToAnchor:volumeContainer.bottomAnchor constant:-2],
    ]];

    // Add containers to stack view
    [_stackView addArrangedSubview:brightnessContainer];
    [_stackView addArrangedSubview:volumeContainer];

    // Update separator visibility
    _separatorLine.hidden = !(_brightnessSliderEnabled && _volumeSliderEnabled);
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        // Stack view fills self
        [_stackView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_stackView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_stackView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_stackView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        // Separator line between sliders
        [_separatorLine.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_separatorLine.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_separatorLine.widthAnchor constraintEqualToAnchor:self.widthAnchor multiplier:0.9],
        [_separatorLine.heightAnchor constraintEqualToConstant:1],
    ]];
}

#pragma mark - Value Updates

- (void)updateBrightnessValue {
    _brightnessSlider.value = [UIScreen mainScreen].brightness;
}

- (void)updateVolumeValue {
    // Volume slider reads MPVolumeController internally
    [_volumeSlider updateSliderValue];
}

#pragma mark - Slider Value Change Callbacks

- (void)brightnessSliderValueChanged:(JadeBrightnessSlider *)slider {
    // The brightness slider itself handles the brightness controller
    // This callback is for any additional handling in the module
}

#pragma mark - Expand/Collapse

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    _isExpanded = expanded;

    CGFloat targetAlpha = expanded ? 1.0f : 0.0f;

    void (^animations)(void) = ^{
        for (UIView *arrangedSubview in self->_stackView.arrangedSubviews) {
            arrangedSubview.alpha = targetAlpha;
        }
        self->_separatorLine.alpha = targetAlpha;
        [self layoutIfNeeded];
    };

    if (animated) {
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:animations completion:nil];
    } else {
        animations();
    }
}

#pragma mark - Tint Color

- (void)setSliderTintColor:(UIColor *)color animated:(BOOL)animated {
    _sliderTintColor = color;

    _brightnessSlider.progressColor = color;
    _brightnessSlider.thumbColor = color;
    [_brightnessSlider updateSliderAppearance];

    _volumeSlider.progressColor = color;
    _volumeSlider.thumbColor = color;
    [_volumeSlider updateSliderAppearance];

    if (animated) {
        [UIView animateWithDuration:0.25 animations:^{
            [self->_brightnessSlider layoutIfNeeded];
            [self->_volumeSlider layoutIfNeeded];
        }];
    }
}

- (void)setSliderTrackColor:(UIColor *)trackColor {
    _sliderTrackColor = trackColor;
    _brightnessSlider.trackColor = trackColor;
    _volumeSlider.trackColor = trackColor;
}

#pragma mark - Observations

- (void)startObservingBrightness {
    if (_isObservingBrightness) return;
    _isObservingBrightness = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateBrightnessValue)
                                                 name:UIScreenBrightnessDidChangeNotification
                                               object:nil];
}

- (void)stopObservingBrightness {
    if (!_isObservingBrightness) return;
    _isObservingBrightness = NO;

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIScreenBrightnessDidChangeNotification
                                                  object:nil];
}

- (void)startObservingVolume {
    if (_isObservingVolume) return;
    _isObservingVolume = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateVolumeValue)
                                                 name:@"AVAudioSessionVolumeDidChangeNotification"
                                               object:nil];
}

- (void)stopObservingVolume {
    if (!_isObservingVolume) return;
    _isObservingVolume = NO;

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:@"AVAudioSessionVolumeDidChangeNotification"
                                                  object:nil];
}

#pragma mark - Update Buttons / Appearance

- (void)updateButtons {
    [self updateSliderEnabledStates];
    [_brightnessSlider updateSliderAppearance];
    [_volumeSlider updateSliderAppearance];
}

#pragma mark - Dealloc

- (void)dealloc {
    [self stopObservingBrightness];
    [self stopObservingVolume];
}

@end
