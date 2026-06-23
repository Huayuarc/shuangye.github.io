// JadeSmallModule.m
// Small compact module view for grid layout in the control center.
// Loads module content from CCSModuleRepository using the module identifier
// and renders it using CCUIButtonModuleView / CCUIContentModuleContainerViewController.

#import "JadeSmallModule.h"
#import <rootless.h>

@interface JadeSmallModule () {
    NSString *_identifier;
    UIViewController *_moduleController;
    id _containerViewController;
    UIView *_ccButton;
}

@property (nonatomic, strong, nullable) NSString *identifier;
@property (nonatomic, strong) UITapGestureRecognizer *tapGesture;

@end

@implementation JadeSmallModule

@synthesize identifier = _identifier;
@synthesize contentView = _contentView;
@synthesize iconImageView = _iconImageView;
@synthesize titleLabel = _titleLabel;
@synthesize subtitleLabel = _subtitleLabel;
@synthesize toggleSwitch = _toggleSwitch;
@synthesize moduleBackgroundColor = _moduleBackgroundColor;
@synthesize moduleTintColor = _moduleTintColor;
@synthesize highlightedColor = _highlightedColor;
@synthesize moduleCornerRadius = _moduleCornerRadius;
@synthesize isActive = _isActive;
@synthesize isHighlighted = _isHighlighted;
@synthesize showsToggle = _showsToggle;
@synthesize toggleState = _toggleState;

#pragma mark - Initialization

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _isActive = NO;
        _isHighlighted = NO;
        _showsToggle = NO;
        _toggleState = NO;
        _moduleCornerRadius = 13.0;
        _moduleBackgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
        _moduleTintColor = [UIColor whiteColor];
        _highlightedColor = [UIColor colorWithWhite:0.25 alpha:1.0];

        [self setupViews];
        [self setupConstraints];

        // Tap gesture for module interaction
        _tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        _tapGesture.numberOfTapsRequired = 1;
        [self addGestureRecognizer:_tapGesture];
    }
    return self;
}

#pragma mark - Setup

- (void)setupViews {
    // Content view - the main container
    _contentView = [[UIView alloc] initWithFrame:CGRectZero];
    _contentView.translatesAutoresizingMaskIntoConstraints = NO;
    _contentView.backgroundColor = _moduleBackgroundColor;
    _contentView.layer.cornerRadius = _moduleCornerRadius;
    _contentView.clipsToBounds = YES;
    _contentView.userInteractionEnabled = YES;
    [self addSubview:_contentView];

    // Icon image view
    _iconImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    _iconImageView.tintColor = _moduleTintColor;
    _iconImageView.hidden = YES;
    [_contentView addSubview:_iconImageView];

    // Title label
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _titleLabel.textColor = _moduleTintColor;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 1;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.7;
    [_contentView addSubview:_titleLabel];

    // Subtitle label
    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightRegular];
    _subtitleLabel.textColor = [_moduleTintColor colorWithAlphaComponent:0.7];
    _subtitleLabel.textAlignment = NSTextAlignmentCenter;
    _subtitleLabel.numberOfLines = 1;
    _subtitleLabel.hidden = YES;
    [_contentView addSubview:_subtitleLabel];

    // Toggle switch
    _toggleSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _toggleSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    _toggleSwitch.hidden = !_showsToggle;
    _toggleSwitch.onTintColor = [UIColor systemGreenColor];
    [_toggleSwitch addTarget:self action:@selector(toggleAction:) forControlEvents:UIControlEventValueChanged];
    [_contentView addSubview:_toggleSwitch];
}

- (void)setupConstraints {
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];

    // Content view fills self
    [constraints addObject:[_contentView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor]];
    [constraints addObject:[_contentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor]];
    [constraints addObject:[_contentView.topAnchor constraintEqualToAnchor:self.topAnchor]];
    [constraints addObject:[_contentView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]];

    // Icon image - centered horizontally, above title
    [constraints addObject:[_iconImageView.centerXAnchor constraintEqualToAnchor:_contentView.centerXAnchor]];
    [constraints addObject:[_iconImageView.centerYAnchor constraintEqualToAnchor:_contentView.centerYAnchor constant:-12]];
    [constraints addObject:[_iconImageView.widthAnchor constraintEqualToConstant:28]];
    [constraints addObject:[_iconImageView.heightAnchor constraintEqualToConstant:28]];

    // Title label - below icon, centered horizontally
    [constraints addObject:[_titleLabel.centerXAnchor constraintEqualToAnchor:_contentView.centerXAnchor]];
    [constraints addObject:[_titleLabel.topAnchor constraintEqualToAnchor:_iconImageView.bottomAnchor constant:4]];
    [constraints addObject:[_titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_contentView.leadingAnchor constant:4]];
    [constraints addObject:[_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_contentView.trailingAnchor constant:-4]];

    // Subtitle label - below title
    [constraints addObject:[_subtitleLabel.centerXAnchor constraintEqualToAnchor:_contentView.centerXAnchor]];
    [constraints addObject:[_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:1]];
    [constraints addObject:[_subtitleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_contentView.leadingAnchor constant:4]];
    [constraints addObject:[_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_contentView.trailingAnchor constant:-4]];

    // Toggle switch - top trailing corner
    [constraints addObject:[_toggleSwitch.topAnchor constraintEqualToAnchor:_contentView.topAnchor constant:6]];
    [constraints addObject:[_toggleSwitch.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor constant:-8]];
    [constraints addObject:[_toggleSwitch.widthAnchor constraintEqualToConstant:51]];
    [constraints addObject:[_toggleSwitch.heightAnchor constraintEqualToConstant:31]];

    [NSLayoutConstraint activateConstraints:constraints];
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    _contentView.layer.cornerRadius = _moduleCornerRadius;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];

    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            // Refresh appearance for dark/light mode
            if (!_moduleBackgroundColor) {
                _contentView.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
            } else {
                _contentView.backgroundColor = _moduleBackgroundColor;
            }
        }
    }
}

#pragma mark - Module Content Loading

- (void)loadModuleContent {
    if (!_identifier || _identifier.length == 0) return;

    // Dynamically load CCSModuleRepository to get module metadata
    Class moduleRepositoryClass = NSClassFromString(@"CCSModuleRepository");
    if (!moduleRepositoryClass) {
        NSLog(@"[Jade] CCSModuleRepository not available");
        return;
    }

    // Get the shared repository instance
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id repository = [moduleRepositoryClass performSelector:NSSelectorFromString(@"sharedInstance")];
    if (!repository) {
        NSLog(@"[Jade] Failed to get CCSModuleRepository sharedInstance");
        return;
    }

    // Fetch module for the given identifier
    SEL moduleForIdentifierSel = NSSelectorFromString(@"moduleForIdentifier:");
    id (*moduleForIdentifier)(id, SEL, NSString *) = (id (*)(id, SEL, NSString *))[repository methodForSelector:moduleForIdentifierSel];
    id module = moduleForIdentifier(repository, moduleForIdentifierSel, _identifier);
    if (!module) {
        NSLog(@"[Jade] No module found for identifier: %@", _identifier);
        return;
    }

    // Create CCUIButtonModuleView for the module
    Class buttonModuleClass = NSClassFromString(@"CCUIButtonModuleView");
    if (buttonModuleClass) {
        _ccButton = [[buttonModuleClass alloc] initWithFrame:self.bounds];
        _ccButton.translatesAutoresizingMaskIntoConstraints = NO;
        _ccButton.userInteractionEnabled = YES;

        // Configure the button module view if it responds to module setup
        SEL setModuleSel = NSSelectorFromString(@"setModule:");
        if ([_ccButton respondsToSelector:setModuleSel]) {
            [_ccButton performSelector:setModuleSel withObject:module];
        }

        [_contentView addSubview:_ccButton];
        [NSLayoutConstraint activateConstraints:@[
            [_ccButton.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor],
            [_ccButton.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor],
            [_ccButton.topAnchor constraintEqualToAnchor:_contentView.topAnchor],
            [_ccButton.bottomAnchor constraintEqualToAnchor:_contentView.bottomAnchor],
        ]];

        // Hide our default UI since the CC button module handles rendering
        _iconImageView.hidden = YES;
        _titleLabel.hidden = YES;
        _subtitleLabel.hidden = YES;
        _toggleSwitch.hidden = YES;
    }

    // Create CCUIContentModuleContainerViewController for expanded module support
    Class containerClass = NSClassFromString(@"CCUIContentModuleContainerViewController");
    if (containerClass) {
        SEL initSel = NSSelectorFromString(@"initWithModuleIdentifier:contentModule:activationStatus:");
        if ([containerClass instancesRespondToSelector:initSel]) {
            id container = [containerClass alloc];
            id (*initializer)(id, SEL, NSString *, id, id) = (id (*)(id, SEL, NSString *, id, id))[container methodForSelector:initSel];
            _containerViewController = initializer(container, initSel, _identifier, module, nil);
        }

        if (!_containerViewController) {
            // Try alternate initializer
            SEL altInitSel = NSSelectorFromString(@"initWithModuleIdentifier:contentModule:");
            if ([containerClass instancesRespondToSelector:altInitSel]) {
                id container = [containerClass alloc];
                id (*initializer)(id, SEL, NSString *, id) = (id (*)(id, SEL, NSString *, id))[container methodForSelector:altInitSel];
                _containerViewController = initializer(container, altInitSel, _identifier, module);
            }
        }

        if (_containerViewController) {
            // Store reference to module controller from the container
            SEL contentModuleSel = NSSelectorFromString(@"contentModule");
            if ([_containerViewController respondsToSelector:contentModuleSel]) {
                _moduleController = [_containerViewController performSelector:contentModuleSel];
            }

            // Add the container's view if available
            SEL moduleViewSel = NSSelectorFromString(@"moduleView");
            if ([_containerViewController respondsToSelector:moduleViewSel]) {
                UIView *moduleView = [_containerViewController performSelector:moduleViewSel];
                if (moduleView && !_ccButton) {
                    moduleView.translatesAutoresizingMaskIntoConstraints = NO;
                    [_contentView addSubview:moduleView];
                    [NSLayoutConstraint activateConstraints:@[
                        [moduleView.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor],
                        [moduleView.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor],
                        [moduleView.topAnchor constraintEqualToAnchor:_contentView.topAnchor],
                        [moduleView.bottomAnchor constraintEqualToAnchor:_contentView.bottomAnchor],
                    ]];
                }
            }
        }
    }
#pragma clang diagnostic pop
}

#pragma mark - Public Methods

- (void)setTitle:(NSString *)title {
    _titleLabel.text = title;
    // If a title is set manually (not from CC module), unhide the title label
    if (_ccButton) {
        // CC button module handles its own title; do not override
        return;
    }
    _titleLabel.hidden = (title.length == 0);
}

- (void)setSubtitle:(NSString *)subtitle {
    _subtitleLabel.text = subtitle;
    _subtitleLabel.hidden = (subtitle.length == 0);
}

- (void)setIcon:(UIImage *)icon {
    _iconImageView.image = icon;
    if (_ccButton) {
        // CC button module handles its own icon; do not override
        return;
    }
    _iconImageView.hidden = (icon == nil);
}

- (void)setActive:(BOOL)active animated:(BOOL)animated {
    _isActive = active;
    if (animated) {
        [UIView animateWithDuration:0.25 animations:^{
            self.contentView.alpha = active ? 1.0 : 0.6;
            self.titleLabel.alpha = active ? 1.0 : 0.5;
        }];
    } else {
        self.contentView.alpha = active ? 1.0 : 0.6;
        self.titleLabel.alpha = active ? 1.0 : 0.5;
    }
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    _isHighlighted = highlighted;
    UIColor *targetColor = highlighted ? _highlightedColor : _moduleBackgroundColor;
    if (animated) {
        [UIView animateWithDuration:0.2 animations:^{
            self->_contentView.backgroundColor = targetColor;
        }];
    } else {
        _contentView.backgroundColor = targetColor;
    }
}

- (void)setModuleBackgroundColor:(UIColor *)color animated:(BOOL)animated {
    _moduleBackgroundColor = color;
    if (animated) {
        [UIView animateWithDuration:0.25 animations:^{
            self->_contentView.backgroundColor = color;
        }];
    } else {
        _contentView.backgroundColor = color;
    }
}

- (void)setModuleBackgroundColor:(UIColor *)color {
    _moduleBackgroundColor = color;
    _contentView.backgroundColor = color;
}

- (void)setModuleTintColor:(UIColor *)color {
    _moduleTintColor = color;
    _titleLabel.textColor = color;
    _subtitleLabel.textColor = [color colorWithAlphaComponent:0.7];
    _iconImageView.tintColor = color;
}

- (void)setToggleState:(BOOL)on animated:(BOOL)animated {
    _toggleState = on;
    [_toggleSwitch setOn:on animated:animated];
}

- (void)toggleAction:(id)sender {
    _toggleState = _toggleSwitch.isOn;
    // Subclasses can override to perform action on toggle
}

#pragma mark - Gesture Handling

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateRecognized) {
        [self setHighlighted:YES animated:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self setHighlighted:NO animated:YES];
        });
    }
}

#pragma mark - Cleanup

- (void)dealloc {
    _tapGesture = nil;
    _moduleController = nil;
    _containerViewController = nil;
    _ccButton = nil;
    _identifier = nil;
}

@end
