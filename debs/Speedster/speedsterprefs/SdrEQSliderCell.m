#import "sdrRootListController.h"
#import <Preferences/PSSliderTableCell.h>
#import <QuartzCore/QuartzCore.h>

// 音频滑块增强 cell：
// - 右侧常驻实时数值（dB 带符号/颜色、Q 值、声道 L/R 百分比）
// - EQ 频段滑块叠加 0dB 中心刻度线
// - 支持 cell 复用（refresh 时按 specifier 重新配置模式）
typedef NS_ENUM(NSUInteger, SdrEQMode) {
    SdrEQModeGain = 0,   // globalGain / masterGain（dB 增益）
    SdrEQModeBand,       // eqBand0~9（带 0dB 中心刻度）
    SdrEQModeQ,          // eqGlobalQ
    SdrEQModePan,        // stereoPan
};

@implementation SdrEQSliderCell {
    UISlider *_slider;
    UILabel *_valueLabel;
    UIView *_centerMarker;
    SdrEQMode _mode;
    NSString *_unit;
    float _minValue;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        _slider = (UISlider *)self.control;
        _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightSemibold];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _valueLabel.adjustsFontSizeToFitWidth = YES;
        _valueLabel.minimumScaleFactor = 0.6;
        _valueLabel.userInteractionEnabled = NO;
        [self.contentView addSubview:_valueLabel];

        [_slider addTarget:self action:@selector(_sliderChanged:) forControlEvents:UIControlEventValueChanged];

        [self _configureForSpecifier:specifier];
        [self _updateValueLabel:_slider.value];
    }
    return self;
}

- (void)_configureForSpecifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    SdrEQMode mode = SdrEQModeGain;
    if ([key hasPrefix:@"eqBand"]) {
        mode = SdrEQModeBand;
    } else if ([key isEqualToString:@"eqGlobalQ"]) {
        mode = SdrEQModeQ;
    } else if ([key isEqualToString:@"stereoPan"]) {
        mode = SdrEQModePan;
    }

    if (mode != _mode) {
        if (_centerMarker) {
            [_centerMarker removeFromSuperview];
            _centerMarker = nil;
        }
        if (mode == SdrEQModeBand) {
            _centerMarker = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1.0, 22.0)];
            _centerMarker.backgroundColor = [UIColor colorWithWhite:0.55 alpha:0.45];
            _centerMarker.userInteractionEnabled = NO;
            _centerMarker.layer.cornerRadius = 0.5;
            [self.contentView addSubview:_centerMarker];
        }
        _mode = mode;
    }

    _unit = [specifier propertyForKey:@"unit"];
    _minValue = _slider.minimumValue;
    [self setNeedsLayout];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self _configureForSpecifier:specifier];
    [self _updateValueLabel:_slider.value];
}

- (void)_sliderChanged:(UISlider *)slider {
    [self _updateValueLabel:slider.value];
}

- (void)_updateValueLabel:(float)value {
    if (!_valueLabel) return;
    NSString *unit = _unit.length ? _unit : @"";
    NSString *text;
    UIColor *color;

    switch (_mode) {
        case SdrEQModePan: {
            float rightPct = (value + 1.0f) * 50.0f;
            rightPct = MAX(0.0f, MIN(100.0f, rightPct));
            text = [NSString stringWithFormat:@"R %0.0f%%", rightPct];
            color = (rightPct > 55.0f) ? [UIColor systemBlueColor]
                  : (rightPct < 45.0f) ? [UIColor systemTealColor]
                  : [UIColor secondaryLabelColor];
            break;
        }
        case SdrEQModeQ:
            text = [NSString stringWithFormat:@"Q %.2f", value];
            color = [UIColor systemPurpleColor];
            break;
        case SdrEQModeBand:
        case SdrEQModeGain:
        default: {
            BOOL signedMode = (_minValue < 0.0f);
            if (value > 0.05f) {
                text = signedMode ? [NSString stringWithFormat:@"+%.1f %@", value, unit]
                                  : [NSString stringWithFormat:@"%.1f %@", value, unit];
                color = [UIColor systemOrangeColor];
            } else if (value < -0.05f) {
                text = [NSString stringWithFormat:@"%.1f %@", value, unit];
                color = [UIColor systemBlueColor];
            } else {
                text = [NSString stringWithFormat:@"0.0 %@", unit];
                color = [UIColor secondaryLabelColor];
            }
            break;
        }
    }

    _valueLabel.text = text;
    _valueLabel.textColor = color;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!_slider || !_valueLabel) return;

    CGRect cv = self.contentView.bounds;
    CGFloat maxX = cv.size.width - 16.0;
    CGFloat labelW = 84.0;
    CGFloat gap = 10.0;

    CGRect sf = _slider.frame;
    CGFloat avail = maxX - sf.origin.x;
    sf.size.width = MAX(40.0, avail - labelW - gap);
    _slider.frame = sf;

    _valueLabel.frame = CGRectMake(CGRectGetMaxX(sf) + gap, 0,
                                   MAX(0, maxX - (CGRectGetMaxX(sf) + gap)),
                                   cv.size.height);

    if (_centerMarker) {
        CGFloat midX = CGRectGetMidX(sf);
        CGFloat midY = CGRectGetMidY(sf);
        CGRect mf = _centerMarker.frame;
        mf.origin.x = midX - mf.size.width * 0.5;
        mf.origin.y = midY - mf.size.height * 0.5;
        _centerMarker.frame = mf;
    }
}

@end
