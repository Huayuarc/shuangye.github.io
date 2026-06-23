// JadeConnectivityButton.m
// Individual connectivity toggle button for the Jade control center
// Combines public header interface with binary-derived ivars and methods

#import "JadeConnectivityButton.h"

// Private class extension for binary-derived ivars and internal state
@interface JadeConnectivityButton () {
    // Binary-derived ivars
    UIImageView *_buttonImageView;
    BOOL _overrideContentMode;
    SEL _action;
    UIImage *_glyphImage;
    UIColor *_selectedTintColor;
}


@end

@implementation JadeConnectivityButton

#pragma mark - Initialization

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _connectivityType = JadeConnectivityTypeWiFi;
        _buttonSize = 56.0;
        _cornerRadius = 14.0;
        _active = NO;
        [super setEnabled:YES];
        _showIndicatorDot = NO;
        _overrideContentMode = NO;
        _action = NULL;
        _glyphImage = nil;
        _selectedTintColor = nil;

        [self setupViews];
        [self setupConstraints];
        [self updateAppearance];

        // Set up pointer interaction (iOS 13.4+)
        if (@available(iOS 13.4, *)) {
            UIPointerInteraction *pointerInteraction = [[UIPointerInteraction alloc] initWithDelegate:nil];
            [self addInteraction:pointerInteraction];
        }
    }
    return self;
}

+ (instancetype)buttonWithConnectivityType:(JadeConnectivityType)type {
    JadeConnectivityButton *button = [[self alloc] initWithFrame:CGRectZero];
    button.connectivityType = type;
    [button.titleLabel setText:[button buttonTitle]];
    button.iconImageView.image = [button buttonIcon];
    button.accessibilityLabel = [button buttonTitle];
    return button;
}

#pragma mark - Setup

- (void)setupViews {
    self.backgroundColor = [UIColor clearColor];
    self.layer.cornerRadius = _cornerRadius;
    self.clipsToBounds = YES;
    self.userInteractionEnabled = YES;

    // Button image view (icon)
    _buttonImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _buttonImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _buttonImageView.contentMode = UIViewContentModeScaleAspectFit;
    _buttonImageView.tintColor = [UIColor whiteColor];
    [self addSubview:_buttonImageView];
    self.iconImageView = _buttonImageView;

    // Title label
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.7;
    [self addSubview:self.titleLabel];

    // Indicator view (small dot for active state feedback)
    self.indicatorView = [[UIView alloc] initWithFrame:CGRectZero];
    self.indicatorView.translatesAutoresizingMaskIntoConstraints = NO;
    self.indicatorView.layer.cornerRadius = 3.0;
    self.indicatorView.hidden = YES;
    self.indicatorView.userInteractionEnabled = NO;
    [self addSubview:self.indicatorView];

    // Accessibility
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
}

- (void)setupConstraints {
    CGFloat iconSize = (_buttonSize > 0) ? (_buttonSize * 0.45) : 24.0;

    [NSLayoutConstraint activateConstraints:@[
        // Icon image view: centered horizontally, slightly above vertical center
        [_buttonImageView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_buttonImageView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-6],
        [_buttonImageView.widthAnchor constraintEqualToConstant:iconSize],
        [_buttonImageView.heightAnchor constraintEqualToConstant:iconSize],

        // Title label: below icon, centered
        [self.titleLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [self.titleLabel.topAnchor constraintEqualToAnchor:_buttonImageView.bottomAnchor constant:3],
        [self.titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:4],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-4],
        [self.titleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-4],

        // Indicator dot: below title label, centered
        [self.indicatorView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [self.indicatorView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
        [self.indicatorView.widthAnchor constraintEqualToConstant:6],
        [self.indicatorView.heightAnchor constraintEqualToConstant:6],
    ]];
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];

    // Center the button image view in the bounds
    _buttonImageView.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds) - 6);

    self.layer.cornerRadius = _cornerRadius;
}

#pragma mark - State Management

- (void)setActive:(BOOL)active animated:(BOOL)animated {
    _active = active;
    self.selected = active;

    void (^updateBlock)(void) = ^{
        [self updateAppearance];
    };

    if (animated) {
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.8
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:updateBlock
                         completion:nil];
    } else {
        updateBlock();
    }
}

- (void)setEnabled:(BOOL)enabled animated:(BOOL)animated {
    [super setEnabled:enabled];
    self.userInteractionEnabled = enabled;

    void (^updateBlock)(void) = ^{
        self.alpha = enabled ? 1.0 : 0.35;
    };

    if (animated) {
        [UIView animateWithDuration:0.25
                              delay:0
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:updateBlock
                         completion:nil];
    } else {
        updateBlock();
    }
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.userInteractionEnabled = enabled;
    self.alpha = enabled ? 1.0 : 0.35;
    [self updateAppearance];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];

    [UIView animateWithDuration:0.15
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.alpha = highlighted ? 0.6 : 1.0;
        self.transform = highlighted ? CGAffineTransformMakeScale(0.92, 0.92) : CGAffineTransformIdentity;
    } completion:nil];
}

- (BOOL)isSelected {
    return self.active;
}

- (void)toggleState {
    self.active = !self.active;
    [self updateAppearance];
}

#pragma mark - Binary-Derived Properties

- (BOOL)overrideContentMode {
    return _overrideContentMode;
}

- (void)setOverrideContentMode:(BOOL)override {
    _overrideContentMode = override;
    if (_overrideContentMode && _glyphImage) {
        _buttonImageView.contentMode = UIViewContentModeScaleAspectFill;
    } else {
        _buttonImageView.contentMode = UIViewContentModeScaleAspectFit;
    }
}

- (SEL)action {
    return _action;
}

- (void)setAction:(SEL)action {
    _action = action;
}

- (UIImage *)glyphImage {
    return _glyphImage;
}

- (void)setGlyphImage:(UIImage *)glyphImage {
    _glyphImage = glyphImage;
    _buttonImageView.image = glyphImage;

    if (_overrideContentMode && glyphImage) {
        _buttonImageView.contentMode = UIViewContentModeScaleAspectFill;
    } else {
        _buttonImageView.contentMode = UIViewContentModeScaleAspectFit;
    }
}

- (UIColor *)selectedTintColor {
    return _selectedTintColor;
}

- (void)setSelectedTintColor:(UIColor *)selectedTintColor {
    _selectedTintColor = selectedTintColor;
    [self updateAppearance];
}

#pragma mark - Appearance

- (void)updateAppearance {
    UIColor *color = [self colorForState];

    // Update icon tint
    _buttonImageView.tintColor = color;

    // Update title label color
    self.titleLabel.textColor = color;

    // Update indicator dot
    self.indicatorView.backgroundColor = color;
    self.indicatorView.hidden = !(self.showIndicatorDot && self.active);

    // Update background
    if (self.active) {
        UIColor *bgColor = self.activeColor ?: [color colorWithAlphaComponent:0.15];
        self.backgroundColor = bgColor;
        self.layer.borderWidth = 0;
    } else {
        self.backgroundColor = self.inactiveColor ?: [UIColor colorWithWhite:0.12 alpha:1.0];
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:0.5].CGColor;
    }
}

- (UIColor *)colorForState {
    if (self.active) {
        return _selectedTintColor ?: self.activeColor ?: [self defaultActiveColorForType];
    }
    return self.inactiveColor ?: [UIColor colorWithWhite:0.6 alpha:1.0];
}

- (UIColor *)defaultActiveColorForType {
    switch (self.connectivityType) {
        case JadeConnectivityTypeWiFi:
            return [UIColor colorWithRed:0.039 green:0.518 blue:1.0 alpha:1.0];   // 0A84FF
        case JadeConnectivityTypeBluetooth:
            return [UIColor systemBlueColor];
        case JadeConnectivityTypeAirplaneMode:
            return [UIColor colorWithRed:1.0 green:0.624 blue:0.039 alpha:1.0];   // FF9F0A
        case JadeConnectivityTypeCellular:
            return [UIColor systemGreenColor];
        case JadeConnectivityTypeVPN:
            return [UIColor systemIndigoColor];
        case JadeConnectivityTypePersonalHotspot:
            return [UIColor systemGreenColor];
        case JadeConnectivityTypeAirdrop:
            return [UIColor systemBlueColor];
    }
}

#pragma mark - Button Metadata

- (NSString *)buttonTitle {
    switch (self.connectivityType) {
        case JadeConnectivityTypeWiFi:
            return @"WiFi";
        case JadeConnectivityTypeCellular:
            return @"Cellular";
        case JadeConnectivityTypeBluetooth:
            return @"Bluetooth";
        case JadeConnectivityTypeAirplaneMode:
            return @"Airplane";
        case JadeConnectivityTypeVPN:
            return @"VPN";
        case JadeConnectivityTypePersonalHotspot:
            return @"Hotspot";
        case JadeConnectivityTypeAirdrop:
            return @"AirDrop";
    }
}

- (UIImage *)buttonIcon {
    NSString *symbolName = nil;
    switch (self.connectivityType) {
        case JadeConnectivityTypeWiFi:
            symbolName = @"wifi";
            break;
        case JadeConnectivityTypeCellular:
            symbolName = @"antenna.radiowaves.left.and.right";
            break;
        case JadeConnectivityTypeBluetooth:
            symbolName = @"bluetooth";
            break;
        case JadeConnectivityTypeAirplaneMode:
            symbolName = @"airplane";
            break;
        case JadeConnectivityTypeVPN:
            symbolName = @"network.badge.shield.half.filled";
            break;
        case JadeConnectivityTypePersonalHotspot:
            symbolName = @"personalhotspot";
            break;
        case JadeConnectivityTypeAirdrop:
            symbolName = @"airdrop";
            break;
    }
    UIImage *image = [UIImage systemImageNamed:symbolName];
    if (!image) {
        // Fallback
        image = [UIImage systemImageNamed:@"circle.fill"];
    }
    return image;
}

#pragma mark - Touch Handling

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];

    if (self.action && [self.superview respondsToSelector:self.action]) {
        void (*action)(id, SEL, id) = (void (*)(id, SEL, id))[self.superview methodForSelector:self.action];
        action(self.superview, self.action, self);
    }
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // Expand hit area slightly for better usability
    CGFloat expandMargin = -8.0;
    CGRect expandedBounds = CGRectInset(self.bounds, expandMargin, expandMargin);
    if (CGRectContainsPoint(expandedBounds, point)) {
        return self;
    }
    return [super hitTest:point withEvent:event];
}

#pragma mark - Cleanup


@end
