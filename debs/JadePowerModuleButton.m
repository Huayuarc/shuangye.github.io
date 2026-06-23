// JadePowerModuleButton.m
// Individual power action button for Shutdown, Restart, Respring, Safe Mode, and Lock

#import "JadePowerModuleButton.h"
#import "JadeLocalization.h"

@interface JadePowerModuleButton ()
@property (nonatomic, strong) UIView *backgroundView;
@property (nonatomic, strong) UIPointerInteraction *pointerInteraction;
@end

@implementation JadePowerModuleButton

#pragma mark - Initialization

+ (instancetype)buttonWithActionType:(JadePowerActionType)actionType {
    JadePowerModuleButton *button = [[self alloc] initWithFrame:CGRectZero];
    button.actionType = actionType;
    [button setupViews];
    [button setupConstraints];
    return button;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _buttonSize = 56.0;
        _cornerRadius = 14.0;
        _isDestructive = NO;
        _buttonColor = [UIColor systemGrayColor];
        _highlightedColor = [UIColor systemGray2Color];
        _iconTintColor = [UIColor whiteColor];

        self.translatesAutoresizingMaskIntoConstraints = NO;

        // Pointer interaction
        _pointerInteraction = [[UIPointerInteraction alloc] initWithDelegate:nil];
        [self addInteraction:_pointerInteraction];
    }
    return self;
}

#pragma mark - View Setup

- (void)setupViews {
    // Background View (rounded rect behind icon)
    _backgroundView = [[UIView alloc] initWithFrame:CGRectZero];
    _backgroundView.backgroundColor = self.buttonColor;
    _backgroundView.layer.cornerRadius = self.cornerRadius;
    _backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    _backgroundView.userInteractionEnabled = NO;
    [self addSubview:_backgroundView];

    // Icon Image View
    _iconImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconImageView.image = [self actionIcon];
    _iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    _iconImageView.tintColor = self.iconTintColor;
    _iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconImageView.userInteractionEnabled = NO;
    [self addSubview:_iconImageView];

    // Title Label
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.text = [self actionTitle];
    _titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    _titleLabel.textColor = [UIColor secondaryLabelColor];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.userInteractionEnabled = NO;
    [self addSubview:_titleLabel];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        // Button width/height based on buttonSize
        [self.widthAnchor constraintEqualToConstant:self.buttonSize],
        [self.heightAnchor constraintEqualToConstant:self.buttonSize + 18],  // extra space for label

        // Background View - centered, sized to buttonSize
        [_backgroundView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_backgroundView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_backgroundView.widthAnchor constraintEqualToConstant:self.buttonSize],
        [_backgroundView.heightAnchor constraintEqualToConstant:self.buttonSize],

        // Icon Image View - centered in background
        [_iconImageView.centerXAnchor constraintEqualToAnchor:_backgroundView.centerXAnchor],
        [_iconImageView.centerYAnchor constraintEqualToAnchor:_backgroundView.centerYAnchor],
        [_iconImageView.widthAnchor constraintEqualToConstant:self.buttonSize * 0.5],
        [_iconImageView.heightAnchor constraintEqualToConstant:self.buttonSize * 0.5],

        // Title Label - below background
        [_titleLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_titleLabel.topAnchor constraintEqualToAnchor:_backgroundView.bottomAnchor constant:4],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];
}

#pragma mark - Touch Handling

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.15 animations:^{
        self.alpha = 0.6;
        self.transform = CGAffineTransformMakeScale(0.92, 0.92);
    }];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.alpha = 1.0;
        self.transform = CGAffineTransformIdentity;
    } completion:nil];

    // Trigger action if touch was inside bounds
    UITouch *touch = [touches anyObject];
    CGPoint location = [touch locationInView:self];
    if (CGRectContainsPoint(self.bounds, location)) {
        [self sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [UIView animateWithDuration:0.25 animations:^{
        self.alpha = 1.0;
        self.transform = CGAffineTransformIdentity;
    }];
}

#pragma mark - Custom Highlight

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.15 animations:^{
        self.alpha = highlighted ? 0.6 : 1.0;
    }];
}

- (BOOL)isSelected {
    return [super isSelected];
}

#pragma mark - Button Appearance

- (void)setButtonColor:(UIColor *)color animated:(BOOL)animated {
    _buttonColor = color;
    NSTimeInterval duration = animated ? 0.25 : 0.0;
    [UIView animateWithDuration:duration animations:^{
        self.backgroundView.backgroundColor = color;
    }];
}

- (void)setButtonColor:(UIColor *)color {
    _buttonColor = color;
    self.backgroundView.backgroundColor = color;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    self.backgroundView.layer.cornerRadius = cornerRadius;
}

- (void)setIconTintColor:(UIColor *)iconTintColor {
    _iconTintColor = iconTintColor;
    self.iconImageView.tintColor = iconTintColor;
}

#pragma mark - Action Type Mapping

- (NSString *)actionTitle {
    switch (self.actionType) {
        case JadePowerActionTypeShutdown:
            return JadeLocalizedString(@"SHUTDOWN");
        case JadePowerActionTypeRestart:
            return JadeLocalizedString(@"REBOOT");
        case JadePowerActionTypeRespring:
            return JadeLocalizedString(@"RESPRING");
        case JadePowerActionTypeSafeMode:
            return JadeLocalizedString(@"SAFE_MODE");
        case JadePowerActionTypeLockDevice:
            return JadeLocalizedString(@"LOCK");
        case JadePowerActionTypeExit:
            return JadeLocalizedString(@"EXIT");
    }
}

- (UIImage *)actionIcon {
    switch (self.actionType) {
        case JadePowerActionTypeShutdown:
            return [UIImage systemImageNamed:@"power"];
        case JadePowerActionTypeRestart:
            return [UIImage systemImageNamed:@"arrow.counterclockwise"];
        case JadePowerActionTypeRespring:
            return [UIImage systemImageNamed:@"arrow.2.circlepath"];
        case JadePowerActionTypeSafeMode:
            return [UIImage systemImageNamed:@"shield.fill"];
        case JadePowerActionTypeLockDevice:
            return [UIImage systemImageNamed:@"lock.fill"];
        case JadePowerActionTypeExit:
            return [UIImage systemImageNamed:@"xmark.circle.fill"];
    }
}

#pragma mark - Action Execution

- (void)performAction {
    // Forward to the JadePowerModule via responder chain
    // The parent module will handle actual execution
    [self sendActionsForControlEvents:UIControlEventTouchUpInside];
}

- (void)triggerConfirmation {
    // Vibrate to indicate confirmation needed
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [generator impactOccurred];

    // Flash the button to indicate it was pressed
    [UIView animateWithDuration:0.1 animations:^{
        self.backgroundView.alpha = 0.5;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.1 animations:^{
            self.backgroundView.alpha = 1.0;
        }];
    }];
}

#pragma mark - Pointer Interaction

- (UIPointerRegion *)pointerInteraction:(UIPointerInteraction *)interaction regionForRequest:(UIPointerRegionRequest *)request defaultRegion:(UIPointerRegion *)defaultRegion {
    return defaultRegion;
}

- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)interaction styleForRegion:(UIPointerRegion *)region {
    UITargetedPreview *preview = [[UITargetedPreview alloc] initWithView:self];
    UIPointerLiftEffect *effect = [UIPointerLiftEffect effectWithPreview:preview];
    return [UIPointerStyle styleWithEffect:effect shape:nil];
}


@end
