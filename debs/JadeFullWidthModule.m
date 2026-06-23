// JadeFullWidthModule.m
// Base class for modules that span the full width of the card.
// Provides title, icon, separator, and a content container for module content.

#import "JadeFullWidthModule.h"
#import <rootless.h>

@interface JadeFullWidthModule () {
    NSString *_internalModuleIdentifier;
}

@end

@implementation JadeFullWidthModule

@synthesize contentView = _contentView;
@synthesize titleLabel = _titleLabel;
@synthesize iconImageView = _iconImageView;
@synthesize separatorLine = _separatorLine;
@synthesize moduleBackgroundColor = _moduleBackgroundColor;
@synthesize moduleTintColor = _moduleTintColor;
@synthesize moduleCornerRadius = _moduleCornerRadius;
@synthesize isHighlighted = _isHighlighted;
@synthesize showsSeparator = _showsSeparator;

#pragma mark - Initialization

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _moduleCornerRadius = 13.0;
        _showsSeparator = YES;
        _isHighlighted = NO;
        _moduleBackgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
        _moduleTintColor = [UIColor whiteColor];

        [self setupViews];
        [self setupConstraints];
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
    [self addSubview:_contentView];

    // Title label
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _titleLabel.textColor = _moduleTintColor;
    _titleLabel.numberOfLines = 1;
    _titleLabel.textAlignment = NSTextAlignmentNatural;
    [_contentView addSubview:_titleLabel];

    // Icon image view
    _iconImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    _iconImageView.tintColor = _moduleTintColor;
    _iconImageView.hidden = YES;
    [_contentView addSubview:_iconImageView];

    // Separator line
    _separatorLine = [[UIView alloc] initWithFrame:CGRectZero];
    _separatorLine.translatesAutoresizingMaskIntoConstraints = NO;
    _separatorLine.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.3];
    _separatorLine.hidden = !_showsSeparator;
    [_contentView addSubview:_separatorLine];
}

- (void)setupConstraints {
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];

    // Content view fills self
    [constraints addObject:[_contentView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor]];
    [constraints addObject:[_contentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor]];
    [constraints addObject:[_contentView.topAnchor constraintEqualToAnchor:self.topAnchor]];
    [constraints addObject:[_contentView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]];

    // Title label - top left with padding
    [constraints addObject:[_titleLabel.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant:16]];
    [constraints addObject:[_titleLabel.topAnchor constraintEqualToAnchor:_contentView.topAnchor constant:12]];
    [constraints addObject:[_titleLabel.heightAnchor constraintEqualToConstant:20]];

    // Icon image - leading to title, vertically centered with title
    [constraints addObject:[_iconImageView.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant:16]];
    [constraints addObject:[_iconImageView.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor]];
    [constraints addObject:[_iconImageView.widthAnchor constraintEqualToConstant:18]];
    [constraints addObject:[_iconImageView.heightAnchor constraintEqualToConstant:18]];

    // Separator line - below title
    [constraints addObject:[_separatorLine.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant:16]];
    [constraints addObject:[_separatorLine.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor constant:-16]];
    [constraints addObject:[_separatorLine.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:8]];
    [constraints addObject:[_separatorLine.heightAnchor constraintEqualToConstant:0.5]];

    [NSLayoutConstraint activateConstraints:constraints];
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    // Refresh content view corner radius on layout
    _contentView.layer.cornerRadius = _moduleCornerRadius;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];

    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            // Refresh appearance for dark/light mode changes
            if (!_moduleBackgroundColor) {
                _contentView.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
            } else {
                _contentView.backgroundColor = _moduleBackgroundColor;
            }
        }
    }
}

#pragma mark - Public Methods

- (void)setTitle:(NSString *)title {
    _titleLabel.text = title;
    // If title is set, hide icon so title uses full width; reposition constraints
    if (title.length > 0 && !_iconImageView.hidden) {
        _iconImageView.hidden = YES;
    }
}

- (void)setIcon:(UIImage *)icon {
    _iconImageView.image = icon;
    _iconImageView.hidden = (icon == nil);
    // If icon is set and title exists, adjust leading constraint on title
    if (icon) {
        // Icon visible, title shifts right
        // Layout handles this via constraints
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
    _iconImageView.tintColor = color;
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    _isHighlighted = highlighted;
    CGFloat alpha = highlighted ? 0.7 : 1.0;
    if (animated) {
        [UIView animateWithDuration:0.2 animations:^{
            self.contentView.alpha = alpha;
        }];
    } else {
        self.contentView.alpha = alpha;
    }
}

- (void)showSeparator:(BOOL)show {
    _showsSeparator = show;
    _separatorLine.hidden = !show;
}

#pragma mark - internalModuleIdentifier

- (NSString *)internalModuleIdentifier {
    return _internalModuleIdentifier;
}

- (void)setInternalModuleIdentifier:(NSString *)identifier {
    _internalModuleIdentifier = [identifier copy];
}


@end
