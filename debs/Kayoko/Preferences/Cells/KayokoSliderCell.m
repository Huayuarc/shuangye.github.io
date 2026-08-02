//
//  KayokoSliderCell.m
//  Kayoko
//

#import "KayokoSliderCell.h"

#import <Preferences/PSSpecifier.h>

@implementation KayokoSliderCell {
    UISlider *_slider;
    UILabel *_titleLabel;
    UILabel *_valueLabel;
    UIView *_topSeparator;
    NSString *_formatString;
    CGFloat _titleLabelWidth;
    CGFloat _valueLabelWidth;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];

    if (!self) {
        return nil;
    }

    // Read custom value label width (default 50)
    NSNumber *labelWidthNum = [specifier propertyForKey:@"valueLabelWidth"];

    if (labelWidthNum && [labelWidthNum isKindOfClass:[NSNumber class]]) {
        _valueLabelWidth = [labelWidthNum floatValue];
    } else {
        _valueLabelWidth = 50.0;
    }

    NSNumber *titleLabelWidthNum = [specifier propertyForKey:@"titleLabelWidth"];
    _titleLabelWidth = titleLabelWidthNum ? [titleLabelWidthNum floatValue] : 88.0;

    NSString *title = [specifier name];
    if ([title isKindOfClass:[NSString class]] && [title length] > 0) {
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _titleLabel.adjustsFontForContentSizeCategory = YES;
        _titleLabel.numberOfLines = 1;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.text = title;
        [self.contentView addSubview:_titleLabel];
    }

    // Create slider
    _slider = [[UISlider alloc] init];
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    [_slider addTarget:self action:@selector(sliderValueChanged:) forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:_slider];

    // Create value label (only if showValue is true)
    NSNumber *showValue = [specifier propertyForKey:@"showValue"];

    if (!showValue || [showValue boolValue]) {
        _valueLabel = [[UILabel alloc] init];
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:[UIFont systemFontSize] weight:UIFontWeightRegular];
        _valueLabel.textColor = [UIColor secondaryLabelColor];
        _valueLabel.numberOfLines = 1;
        _valueLabel.lineBreakMode = NSLineBreakByClipping;
        [self.contentView addSubview:_valueLabel];
    }

    if ([[specifier propertyForKey:@"showsTopSeparator"] boolValue]) {
        _topSeparator = [[UIView alloc] init];
        _topSeparator.translatesAutoresizingMaskIntoConstraints = NO;
        _topSeparator.backgroundColor = [UIColor separatorColor];
        [self.contentView addSubview:_topSeparator];
    }

    // Sync slider properties from specifier
    [self _syncWithSpecifier:specifier];

    // Setup constraints
    [self setupConstraints];

    return self;
}

- (void)setupConstraints {
    UILayoutGuide *margins = self.layoutMarginsGuide;
    NSLayoutXAxisAnchor *sliderLeadingAnchor = margins.leadingAnchor;

    if (_topSeparator) {
        [NSLayoutConstraint activateConstraints:@[
            [_topSeparator.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [_topSeparator.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [_topSeparator.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_topSeparator.heightAnchor constraintEqualToConstant:1.0 / [UIScreen mainScreen].scale],
        ]];
    }

    if (_titleLabel) {
        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_titleLabel.widthAnchor constraintEqualToConstant:_titleLabelWidth],
        ]];
        sliderLeadingAnchor = _titleLabel.trailingAnchor;
    }

    if (_valueLabel) {
        // Slider + Value Label layout
        [NSLayoutConstraint activateConstraints:@[
            // Value label on the right
            [_valueLabel.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [_valueLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_valueLabel.widthAnchor constraintEqualToConstant:_valueLabelWidth],

            // Slider fills remaining space
            [_slider.leadingAnchor constraintEqualToAnchor:sliderLeadingAnchor constant:(_titleLabel ? 12.0 : 0.0)],
            [_slider.trailingAnchor constraintEqualToAnchor:_valueLabel.leadingAnchor constant:-12],
            [_slider.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
    } else {
        // Slider only layout
        [NSLayoutConstraint activateConstraints:@[
            [_slider.leadingAnchor constraintEqualToAnchor:sliderLeadingAnchor constant:(_titleLabel ? 12.0 : 0.0)],
            [_slider.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [_slider.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
    }

    // Fixed height constraint
    [NSLayoutConstraint activateConstraints:@[
        [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
    ]];
}

- (void)_syncWithSpecifier:(PSSpecifier *)specifier {
    if (!specifier) {
        return;
    }

    _formatString = [specifier propertyForKey:@"format"];

    if (!_formatString || ![_formatString isKindOfClass:[NSString class]]) {
        _formatString = @"%.0f";
    }

    NSNumber *minValue = [specifier propertyForKey:@"min"];
    NSNumber *maxValue = [specifier propertyForKey:@"max"];

    if (minValue) {
        _slider.minimumValue = [minValue floatValue];
    }

    if (maxValue) {
        _slider.maximumValue = [maxValue floatValue];
    }

    NSNumber *isContinuous = [specifier propertyForKey:@"isContinuous"];
    _slider.continuous = isContinuous ? [isContinuous boolValue] : YES;

    NSNumber *enabled = [specifier propertyForKey:@"enabled"];
    BOOL isEnabled = !enabled || [enabled boolValue];
    [self setKayokoControlEnabled:isEnabled];

    id value = [specifier performGetter];

    if ([value isKindOfClass:[NSNumber class]]) {
        _slider.value = [value floatValue];
    } else {
        NSNumber *defaultValue = [specifier propertyForKey:@"default"];

        if (defaultValue) {
            _slider.value = [defaultValue floatValue];
        }
    }

    [self updateValueLabel];
}

- (void)setKayokoControlEnabled:(BOOL)enabled {
    _slider.enabled = enabled;
    _titleLabel.textColor = enabled ? [UIColor labelColor] : [UIColor tertiaryLabelColor];
    _valueLabel.textColor = enabled ? [UIColor secondaryLabelColor] : [UIColor tertiaryLabelColor];
}

- (void)setSpecifier:(PSSpecifier *)specifier {
    [super setSpecifier:specifier];
    [self _syncWithSpecifier:specifier];
}

- (void)updateValueLabel {
    if (_valueLabel) {
        _valueLabel.text = [NSString stringWithFormat:_formatString, _slider.value];
    }
}

- (void)sliderValueChanged:(UISlider *)slider {
    PSSpecifier *specifier = self.specifier;

    // Handle segmented slider - snap to discrete values
    NSNumber *isSegmented = [specifier propertyForKey:@"isSegmented"];

    if (isSegmented && [isSegmented boolValue]) {
        NSNumber *segmentCount = [specifier propertyForKey:@"segmentCount"];

        if (segmentCount && [segmentCount integerValue] > 0) {
            NSInteger segments = [segmentCount integerValue];
            CGFloat range = slider.maximumValue - slider.minimumValue;
            CGFloat step = range / (CGFloat)segments;
            CGFloat normalizedValue = (slider.value - slider.minimumValue) / step;
            CGFloat snappedValue = slider.minimumValue + (round(normalizedValue) * step);
            slider.value = snappedValue;
        }
    }

    // Update value label
    [self updateValueLabel];

    // Notify the specifier's target - use performSetterWithValue method
    if (specifier) {
        NSNumber *value = @(slider.value);
        [specifier performSetterWithValue:value];
    }
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self _syncWithSpecifier:specifier];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _slider.value = _slider.minimumValue;
    [self updateValueLabel];
}

@end
