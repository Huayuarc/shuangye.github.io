#import "DIContentView.h"
#import "DILocalization.h"

#define kPrefsPath @"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"

static CGFloat const kFullCornerRadius = 22.0;
static CGFloat const kArtworkSizeCompact = 26.0;
static CGFloat const kArtworkSizeFull = 64.0;
static CGFloat const kPadding = 6.0;

// Defaults
static CGFloat _prefCompactW = 155.0;
static CGFloat _prefCompactH = 35.0;
static CGFloat _prefExpandedW = 340.0;
static CGFloat _prefFullW = 370.0;
static CGFloat _prefFullH = 175.0;
static CGFloat _prefYOffset = 45.0;
static CGFloat _prefReappearDelay = 1.0;
static CGFloat _prefMediaCorner = 18.0;
static CGFloat _prefNotifCorner = 22.0;
// 边框
static BOOL    _prefBorderEnabled = NO;
static CGFloat _prefBorderWidth = 1.5;
static CGFloat _prefBorderR = 1.0;
static CGFloat _prefBorderG = 1.0;
static CGFloat _prefBorderB = 1.0;

@interface DIContentView ()
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UIView *marqueeContainer;
@property (nonatomic, strong) UILabel *marqueeLabel;
@property (nonatomic, strong) UILabel *marqueeLabelCopy;
@property (nonatomic, strong) CADisplayLink *marqueeLink;
@property (nonatomic, assign) CGFloat marqueeOffset;
@property (nonatomic, strong) NSArray<CALayer *> *waveBars;
@property (nonatomic, strong) CADisplayLink *waveLink;
@property (nonatomic, strong) UIButton *prevButton;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIView *fullControlsView;
@property (nonatomic, strong) UIButton *fullPrevButton;
@property (nonatomic, strong) UIButton *fullPlayPauseButton;
@property (nonatomic, strong) UIButton *fullNextButton;
@property (nonatomic, strong) UISlider *progressSlider;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UILabel *remainingLabel;
@property (nonatomic, assign) NSTimeInterval trackDuration;
@property (nonatomic, assign) NSTimeInterval trackElapsed;
@property (nonatomic, assign) BOOL isSeeking;
@property (nonatomic, strong) CADisplayLink *progressLink;
@property (nonatomic, strong) UIImpactFeedbackGenerator *feedbackGenerator;
// 通知视图组件
@property (nonatomic, strong) UIView *notificationContainer;
@property (nonatomic, strong) UIImageView *notifIconView;
@property (nonatomic, strong) UILabel *notifTitleLabel;
@property (nonatomic, strong) UILabel *notifMessageLabel;
// 通知消息滚动（compact 模式）
@property (nonatomic, strong) UIView *notifMsgMarqueeContainer;
@property (nonatomic, strong) UILabel *notifMsgMarqueeLabel;
@property (nonatomic, strong) UILabel *notifMsgMarqueeLabelCopy;
@property (nonatomic, strong) CADisplayLink *notifMarqueeLink;
@property (nonatomic, assign) CGFloat notifMarqueeOffset;
// 通知展开状态
@property (nonatomic, assign) BOOL notifExpanded;
@end

@implementation DIContentView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor blackColor];
        self.layer.cornerRadius = _prefMediaCorner;
        self.layer.cornerCurve = kCACornerCurveCircular;
        self.clipsToBounds = YES;
        self.alpha = 0.0;
        self.transform = CGAffineTransformMakeScale(0.8, 0.8);
        self.state = DIStateHidden;

        _artworkView = [[UIImageView alloc] init];
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.clipsToBounds = YES;
        _artworkView.layer.cornerRadius = 4.0;
        _artworkView.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
        [self addSubview:_artworkView];

        _marqueeContainer = [[UIView alloc] init];
        _marqueeContainer.clipsToBounds = YES;
        [self addSubview:_marqueeContainer];

        _marqueeLabel = [[UILabel alloc] init];
        _marqueeLabel.textColor = [UIColor whiteColor];
        _marqueeLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [_marqueeContainer addSubview:_marqueeLabel];

        _marqueeLabelCopy = [[UILabel alloc] init];
        _marqueeLabelCopy.textColor = [UIColor whiteColor];
        _marqueeLabelCopy.font = _marqueeLabel.font;
        _marqueeLabelCopy.hidden = YES;
        [_marqueeContainer addSubview:_marqueeLabelCopy];

        NSMutableArray *bars = [NSMutableArray array];
        for (int i = 0; i < 4; i++) {
            CALayer *bar = [CALayer layer];
            bar.backgroundColor = [UIColor colorWithRed:0.3 green:0.85 blue:0.4 alpha:1.0].CGColor;
            bar.cornerRadius = 1.5;
            [self.layer addSublayer:bar];
            [bars addObject:bar];
        }
        _waveBars = bars;

        _prevButton = [self makeCtrl:@"backward.fill" size:14];
        [_prevButton addTarget:self action:@selector(prevTapped) forControlEvents:UIControlEventTouchUpInside];
        _prevButton.alpha = 0; _prevButton.hidden = YES;
        [self addSubview:_prevButton];

        _playPauseButton = [self makeCtrl:@"pause.fill" size:14];
        [_playPauseButton addTarget:self action:@selector(playPauseTapped) forControlEvents:UIControlEventTouchUpInside];
        _playPauseButton.alpha = 0; _playPauseButton.hidden = YES;
        [self addSubview:_playPauseButton];

        _nextButton = [self makeCtrl:@"forward.fill" size:14];
        [_nextButton addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];
        _nextButton.alpha = 0; _nextButton.hidden = YES;
        [self addSubview:_nextButton];

        _fullControlsView = [[UIView alloc] init];
        _fullControlsView.alpha = 0; _fullControlsView.hidden = YES;
        [self addSubview:_fullControlsView];

        _fullPrevButton = [self makeCtrl:@"backward.fill" size:22];
        [_fullPrevButton addTarget:self action:@selector(prevTapped) forControlEvents:UIControlEventTouchUpInside];
        [_fullControlsView addSubview:_fullPrevButton];

        _fullPlayPauseButton = [self makeCtrl:@"pause.fill" size:28];
        [_fullPlayPauseButton addTarget:self action:@selector(playPauseTapped) forControlEvents:UIControlEventTouchUpInside];
        [_fullControlsView addSubview:_fullPlayPauseButton];

        _fullNextButton = [self makeCtrl:@"forward.fill" size:22];
        [_fullNextButton addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];
        [_fullControlsView addSubview:_fullNextButton];

        _progressSlider = [[UISlider alloc] init];
        _progressSlider.minimumValue = 0;
        _progressSlider.maximumValue = 1.0;
        _progressSlider.value = 0;
        _progressSlider.minimumTrackTintColor = [UIColor whiteColor];
        _progressSlider.maximumTrackTintColor = [UIColor colorWithWhite:0.3 alpha:1.0];
        [_progressSlider setThumbImage:[self thumbImageWithSize:8] forState:UIControlStateNormal];
        [_progressSlider setThumbImage:[self thumbImageWithSize:12] forState:UIControlStateHighlighted];
        [_progressSlider addTarget:self action:@selector(sliderBegan:) forControlEvents:UIControlEventTouchDown];
        [_progressSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [_progressSlider addTarget:self action:@selector(sliderEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        _progressSlider.alpha = 0; _progressSlider.hidden = YES;
        [self addSubview:_progressSlider];

        _elapsedLabel = [[UILabel alloc] init];
        _elapsedLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular];
        _elapsedLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        _elapsedLabel.text = @"0:00";
        _elapsedLabel.alpha = 0; _elapsedLabel.hidden = YES;
        [self addSubview:_elapsedLabel];

        _remainingLabel = [[UILabel alloc] init];
        _remainingLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular];
        _remainingLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        _remainingLabel.textAlignment = NSTextAlignmentRight;
        _remainingLabel.text = @"-0:00";
        _remainingLabel.alpha = 0; _remainingLabel.hidden = YES;
        [self addSubview:_remainingLabel];

        _artistLabel = [[UILabel alloc] init];
        _artistLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
        _artistLabel.font = [UIFont systemFontOfSize:13];
        _artistLabel.alpha = 0; _artistLabel.hidden = YES;
        [self addSubview:_artistLabel];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        _titleLabel.alpha = 0; _titleLabel.hidden = YES;
        [self addSubview:_titleLabel];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        [self addGestureRecognizer:tap];

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        lp.minimumPressDuration = 0.3;
        [self addGestureRecognizer:lp];

        UISwipeGestureRecognizer *sr = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipeRight)];
        sr.direction = UISwipeGestureRecognizerDirectionRight;
        [self addGestureRecognizer:sr];

        UISwipeGestureRecognizer *sl = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipeLeft)];
        sl.direction = UISwipeGestureRecognizerDirectionLeft;
        [self addGestureRecognizer:sl];

        UISwipeGestureRecognizer *su = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipeUp)];
        su.direction = UISwipeGestureRecognizerDirectionUp;
        [self addGestureRecognizer:su];

        _feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [_feedbackGenerator prepare];

        // 通知容器（默认隐藏）
        _notificationContainer = [[UIView alloc] init];
        _notificationContainer.alpha = 0;
        _notificationContainer.hidden = YES;
        [self addSubview:_notificationContainer];

        _notifIconView = [[UIImageView alloc] init];
        _notifIconView.contentMode = UIViewContentModeScaleAspectFit;
        _notifIconView.clipsToBounds = YES;
        _notifIconView.layer.cornerRadius = 6.0;
        _notifIconView.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
        [_notificationContainer addSubview:_notifIconView];

        _notifTitleLabel = [[UILabel alloc] init];
        _notifTitleLabel.textColor = [UIColor whiteColor];
        _notifTitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _notifTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_notificationContainer addSubview:_notifTitleLabel];

        _notifMessageLabel = [[UILabel alloc] init];
        _notifMessageLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
        _notifMessageLabel.font = [UIFont systemFontOfSize:12];
        _notifMessageLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _notifMessageLabel.numberOfLines = 1;
        [_notificationContainer addSubview:_notifMessageLabel];

        // 通知消息滚动容器（compact 模式下长消息滚动）
        _notifMsgMarqueeContainer = [[UIView alloc] init];
        _notifMsgMarqueeContainer.clipsToBounds = YES;
        _notifMsgMarqueeContainer.hidden = YES;
        [_notificationContainer addSubview:_notifMsgMarqueeContainer];

        _notifMsgMarqueeLabel = [[UILabel alloc] init];
        _notifMsgMarqueeLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
        _notifMsgMarqueeLabel.font = [UIFont systemFontOfSize:12];
        [_notifMsgMarqueeContainer addSubview:_notifMsgMarqueeLabel];

        _notifMsgMarqueeLabelCopy = [[UILabel alloc] init];
        _notifMsgMarqueeLabelCopy.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
        _notifMsgMarqueeLabelCopy.font = [UIFont systemFontOfSize:12];
        _notifMsgMarqueeLabelCopy.hidden = YES;
        [_notifMsgMarqueeContainer addSubview:_notifMsgMarqueeLabelCopy];
    }
    return self;
}

- (void)reloadPrefs {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: @{};
    if (prefs[@"compactW"]) _prefCompactW = [prefs[@"compactW"] floatValue];
    if (prefs[@"compactH"]) _prefCompactH = [prefs[@"compactH"] floatValue];
    if (prefs[@"expandedW"]) _prefExpandedW = [prefs[@"expandedW"] floatValue];
    if (prefs[@"fullW"]) _prefFullW = [prefs[@"fullW"] floatValue];
    if (prefs[@"fullH"]) _prefFullH = [prefs[@"fullH"] floatValue];
    if (prefs[@"yOffset"]) _prefYOffset = [prefs[@"yOffset"] floatValue];
    if (prefs[@"reappearDelay"]) _prefReappearDelay = [prefs[@"reappearDelay"] floatValue];
    if (prefs[@"mediaCornerRadius"]) _prefMediaCorner = [prefs[@"mediaCornerRadius"] floatValue];
    if (prefs[@"notifCornerRadius"]) _prefNotifCorner = [prefs[@"notifCornerRadius"] floatValue];
    // 边框
    _prefBorderEnabled = prefs[@"borderEnabled"] ? [prefs[@"borderEnabled"] boolValue] : NO;
    if (prefs[@"borderWidth"]) _prefBorderWidth = [prefs[@"borderWidth"] floatValue];
    if (prefs[@"borderR"]) _prefBorderR = [prefs[@"borderR"] floatValue] / 255.0;
    if (prefs[@"borderG"]) _prefBorderG = [prefs[@"borderG"] floatValue] / 255.0;
    if (prefs[@"borderB"]) _prefBorderB = [prefs[@"borderB"] floatValue] / 255.0;

    // 立即把当前圆角应用到层
    if (self.contentType == DIContentTypeNotification) {
        self.layer.cornerRadius = _prefNotifCorner;
    } else {
        self.layer.cornerRadius = _prefMediaCorner;
    }
    [self applyBorder];
}

- (void)applyBorder {
    if (_prefBorderEnabled) {
        UIColor *c = [UIColor colorWithRed:_prefBorderR green:_prefBorderG blue:_prefBorderB alpha:1.0];
        self.layer.borderColor = c.CGColor;
        self.layer.borderWidth = _prefBorderWidth;
    } else {
        self.layer.borderWidth = 0;
        self.layer.borderColor = nil;
    }
}

- (UIButton *)makeCtrl:(NSString *)sfName size:(CGFloat)size {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightMedium];
    [btn setImage:[UIImage systemImageNamed:sfName withConfiguration:cfg] forState:UIControlStateNormal];
    btn.tintColor = [UIColor whiteColor];
    return btn;
}

- (UIImage *)thumbImageWithSize:(CGFloat)size {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    [[UIColor whiteColor] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, size, size)] fill];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    if (self.contentType == DIContentTypeNotification) {
        [self layoutNotificationContent];
        return;
    }
    if (self.state == DIStateExpandedFull) [self layoutFullPanel:b];
    else if (self.state == DIStateExpanded) [self layoutExpanded:b];
    else [self layoutCompact:b];
}

- (void)layoutCompact:(CGRect)b {
    CGFloat artS = kArtworkSizeCompact;
    CGFloat artY = (b.size.height - artS) / 2;
    self.artworkView.frame = CGRectMake(kPadding, artY, artS, artS);
    self.artworkView.layer.cornerRadius = 4.0;

    CGFloat marqueeX = kPadding + artS + 5;
    CGFloat waveW = 20;
    CGFloat marqueeW = b.size.width - marqueeX - waveW - kPadding;
    self.marqueeContainer.frame = CGRectMake(marqueeX, 0, marqueeW, b.size.height);

    CGFloat labelH = self.marqueeLabel.bounds.size.height;
    CGFloat labelY = (b.size.height - labelH) / 2;
    CGRect mf = self.marqueeLabel.frame; mf.origin.y = labelY; self.marqueeLabel.frame = mf;
    CGRect cf = self.marqueeLabelCopy.frame; cf.origin.y = labelY; self.marqueeLabelCopy.frame = cf;

    CGFloat barW = 3.0, barSpacing = 2.0;
    CGFloat totalW = 4 * barW + 3 * barSpacing;
    CGFloat barX = b.size.width - kPadding - totalW;
    for (int i = 0; i < 4; i++) {
        CGFloat h = 8 + arc4random_uniform(8);
        self.waveBars[i].frame = CGRectMake(barX + i * (barW + barSpacing), (b.size.height - h) / 2, barW, h);
        self.waveBars[i].hidden = NO;
    }
    self.prevButton.hidden = YES; self.playPauseButton.hidden = YES; self.nextButton.hidden = YES;
    self.fullControlsView.hidden = YES; self.titleLabel.hidden = YES; self.artistLabel.hidden = YES;
    self.progressSlider.hidden = YES; self.elapsedLabel.hidden = YES; self.remainingLabel.hidden = YES;
}

- (void)layoutExpanded:(CGRect)b {
    CGFloat artS = kArtworkSizeCompact;
    CGFloat artY = (b.size.height - artS) / 2;
    self.artworkView.frame = CGRectMake(kPadding, artY, artS, artS);
    self.artworkView.layer.cornerRadius = 4.0;

    CGFloat ctrlW = 100, btnSize = 30;
    CGFloat ctrlX = b.size.width - ctrlW - kPadding;
    self.prevButton.hidden = NO; self.prevButton.alpha = 1;
    self.playPauseButton.hidden = NO; self.playPauseButton.alpha = 1;
    self.nextButton.hidden = NO; self.nextButton.alpha = 1;
    self.prevButton.frame = CGRectMake(ctrlX, (b.size.height - btnSize)/2, btnSize, btnSize);
    self.playPauseButton.frame = CGRectMake(ctrlX + 35, (b.size.height - btnSize)/2, btnSize, btnSize);
    self.nextButton.frame = CGRectMake(ctrlX + 70, (b.size.height - btnSize)/2, btnSize, btnSize);

    CGFloat marqueeX = kPadding + artS + 5;
    CGFloat marqueeW = ctrlX - marqueeX - 5;
    self.marqueeContainer.frame = CGRectMake(marqueeX, 0, marqueeW, b.size.height);
    CGFloat labelH = self.marqueeLabel.bounds.size.height;
    CGFloat labelY = (b.size.height - labelH) / 2;
    CGRect mf = self.marqueeLabel.frame; mf.origin.y = labelY; self.marqueeLabel.frame = mf;
    CGRect cf = self.marqueeLabelCopy.frame; cf.origin.y = labelY; self.marqueeLabelCopy.frame = cf;

    for (CALayer *bar in self.waveBars) bar.hidden = YES;
    self.fullControlsView.hidden = YES; self.titleLabel.hidden = YES; self.artistLabel.hidden = YES;
    self.progressSlider.hidden = YES; self.elapsedLabel.hidden = YES; self.remainingLabel.hidden = YES;
}

- (void)layoutFullPanel:(CGRect)b {
    CGFloat artS = kArtworkSizeFull;
    self.artworkView.frame = CGRectMake(16, 16, artS, artS);
    self.artworkView.layer.cornerRadius = 8.0;

    CGFloat textX = 16 + artS + 12;
    CGFloat textW = b.size.width - textX - 60;
    self.titleLabel.hidden = NO; self.titleLabel.alpha = 1;
    self.titleLabel.frame = CGRectMake(textX, 20, textW, 22);
    self.artistLabel.hidden = NO; self.artistLabel.alpha = 1;
    self.artistLabel.frame = CGRectMake(textX, 44, textW, 18);

    CGFloat barW = 4.0, barSpacing = 3.0;
    CGFloat totalBarW = 4 * barW + 3 * barSpacing;
    CGFloat barX = b.size.width - 20 - totalBarW;
    for (int i = 0; i < 4; i++) {
        CGFloat h = 12 + arc4random_uniform(12);
        self.waveBars[i].frame = CGRectMake(barX + i * (barW + barSpacing), 24, barW, h);
        self.waveBars[i].hidden = NO;
    }

    self.marqueeContainer.hidden = YES;
    self.prevButton.hidden = YES; self.playPauseButton.hidden = YES; self.nextButton.hidden = YES;

    CGFloat sliderY = 16 + artS + 10;
    CGFloat sliderX = 20, sliderW = b.size.width - 40;
    self.progressSlider.hidden = NO; self.progressSlider.alpha = 1;
    self.progressSlider.frame = CGRectMake(sliderX, sliderY, sliderW, 20);
    self.elapsedLabel.hidden = NO; self.elapsedLabel.alpha = 1;
    self.elapsedLabel.frame = CGRectMake(sliderX, sliderY + 20, 50, 14);
    self.remainingLabel.hidden = NO; self.remainingLabel.alpha = 1;
    self.remainingLabel.frame = CGRectMake(sliderX + sliderW - 50, sliderY + 20, 50, 14);

    self.fullControlsView.hidden = NO; self.fullControlsView.alpha = 1;
    CGFloat ctrlH = 50, ctrlY = b.size.height - ctrlH - 12;
    self.fullControlsView.frame = CGRectMake(0, ctrlY, b.size.width, ctrlH);
    CGFloat btnS = 44, cx = b.size.width / 2;
    self.fullPrevButton.frame = CGRectMake(cx - 80, (ctrlH - btnS)/2, btnS, btnS);
    self.fullPlayPauseButton.frame = CGRectMake(cx - btnS/2, (ctrlH - btnS)/2, btnS, btnS);
    self.fullNextButton.frame = CGRectMake(cx + 36, (ctrlH - btnS)/2, btnS, btnS);
}

#pragma mark - Show / Hide

- (void)showWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    self.contentType = DIContentTypeMedia;
    self.titleText = title;
    self.subtitleText = subtitle;
    self.state = DIStateCompact;

    [self updateMarqueeText];
    self.titleLabel.text = title;
    self.artistLabel.text = subtitle;
    self.marqueeContainer.hidden = NO;

    CGRect superBounds = self.superview.bounds;
    self.transform = CGAffineTransformIdentity;
    self.frame = CGRectMake((superBounds.size.width - _prefCompactW) / 2, _prefYOffset, _prefCompactW, _prefCompactH);
    self.layer.cornerRadius = _prefMediaCorner;
    self.transform = CGAffineTransformMakeScale(0.8, 0.8);

    [UIView animateWithDuration:0.35 delay:0
         usingSpringWithDamping:0.75 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.alpha = 1.0;
        self.transform = CGAffineTransformIdentity;
    } completion:^(BOOL f) {
        [self startMarquee];
        [self startWaveAnimation];
    }];
}

- (void)hide {
    [self stopMarquee];
    [self stopWaveAnimation];
    [self stopProgressLink];
    [UIView animateWithDuration:0.25 animations:^{
        self.alpha = 0.0;
        self.transform = CGAffineTransformMakeScale(0.8, 0.8);
    } completion:^(BOOL f) {
        self.state = DIStateHidden;
    }];
}

#pragma mark - Expand / Collapse

- (void)expand {
    if (self.state != DIStateCompact) return;
    self.state = DIStateExpanded;
    [self.feedbackGenerator impactOccurred];
    [self stopWaveAnimation];
    self.transform = CGAffineTransformIdentity;

    CGFloat screenW = self.superview.bounds.size.width;
    CGRect f = CGRectMake((screenW - _prefExpandedW) / 2, _prefYOffset, _prefExpandedW, _prefCompactH);

    [UIView animateWithDuration:0.4 delay:0
         usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ self.frame = f; }
                     completion:^(BOOL finished) {
        [self setNeedsLayout]; [self layoutIfNeeded];
    }];
}

- (void)collapse {
    if (self.state == DIStateExpanded) {
        self.state = DIStateCompact;
        [self animateToCompact];
        [self startWaveAnimation];
    } else if (self.state == DIStateExpandedFull) {
        [self collapseFull];
    }
}

- (void)expandFull {
    if (self.state == DIStateHidden) return;
    self.state = DIStateExpandedFull;
    [self.feedbackGenerator impactOccurred];
    [self stopMarquee];
    [self startWaveAnimation];
    self.transform = CGAffineTransformIdentity;

    CGFloat screenW = self.superview.bounds.size.width;
    CGRect f = CGRectMake((screenW - _prefFullW) / 2, _prefYOffset, _prefFullW, _prefFullH);

    [UIView animateWithDuration:0.4 delay:0
         usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.frame = f;
        self.layer.cornerRadius = kFullCornerRadius;
    } completion:^(BOOL finished) {
        [self setNeedsLayout]; [self layoutIfNeeded];
    }];
}

- (void)collapseFull {
    self.state = DIStateCompact;
    self.marqueeContainer.hidden = NO;
    [self animateToCompact];
    [self startMarquee];
    [self startWaveAnimation];
}

- (void)animateToCompact {
    CGFloat screenW = self.superview.bounds.size.width;
    CGRect targetFrame = CGRectMake((screenW - _prefCompactW) / 2, _prefYOffset, _prefCompactW, _prefCompactH);

    [UIView animateWithDuration:0.4 delay:0
         usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.transform = CGAffineTransformIdentity;
        self.frame = targetFrame;
        self.layer.cornerRadius = _prefMediaCorner;
        self.prevButton.alpha = 0; self.playPauseButton.alpha = 0; self.nextButton.alpha = 0;
        self.fullControlsView.alpha = 0; self.titleLabel.alpha = 0; self.artistLabel.alpha = 0;
        self.progressSlider.alpha = 0; self.elapsedLabel.alpha = 0; self.remainingLabel.alpha = 0;
    } completion:^(BOOL finished) {
        self.prevButton.hidden = YES; self.playPauseButton.hidden = YES; self.nextButton.hidden = YES;
        self.fullControlsView.hidden = YES; self.titleLabel.hidden = YES; self.artistLabel.hidden = YES;
        self.progressSlider.hidden = YES; self.elapsedLabel.hidden = YES; self.remainingLabel.hidden = YES;
        [self setNeedsLayout]; [self layoutIfNeeded];
    }];
}

#pragma mark - Marquee

- (void)updateMarqueeText {
    NSString *text = self.subtitleText ?: @"";
    if (text.length == 0) text = self.titleText ?: @"";
    self.marqueeLabel.text = text;
    self.marqueeLabelCopy.text = text;
    [self.marqueeLabel sizeToFit];
    [self.marqueeLabelCopy sizeToFit];

    CGFloat containerW = self.marqueeContainer.bounds.size.width;
    CGFloat textW = self.marqueeLabel.bounds.size.width;
    self.marqueeLabel.frame = CGRectMake(0, (self.marqueeContainer.bounds.size.height - self.marqueeLabel.bounds.size.height)/2, textW, self.marqueeLabel.bounds.size.height);
    if (textW > containerW) {
        CGFloat gap = 40;
        self.marqueeLabelCopy.hidden = NO;
        self.marqueeLabelCopy.frame = CGRectMake(textW + gap, self.marqueeLabel.frame.origin.y, textW, self.marqueeLabel.bounds.size.height);
    } else {
        self.marqueeLabelCopy.hidden = YES;
    }
    self.marqueeOffset = 0;
}

- (void)startMarquee {
    if (self.marqueeLink) return;
    self.marqueeLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(marqueeStep)];
    [self.marqueeLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopMarquee {
    [self.marqueeLink invalidate];
    self.marqueeLink = nil;
}

- (void)marqueeStep {
    CGFloat textW = self.marqueeLabel.bounds.size.width;
    CGFloat containerW = self.marqueeContainer.bounds.size.width;
    if (textW <= containerW) return;
    CGFloat gap = 40, speed = 0.5;
    self.marqueeOffset += speed;
    CGFloat totalW = textW + gap;
    if (self.marqueeOffset >= totalW) self.marqueeOffset = 0;
    CGFloat y = self.marqueeLabel.frame.origin.y;
    self.marqueeLabel.frame = CGRectMake(-self.marqueeOffset, y, textW, self.marqueeLabel.bounds.size.height);
    self.marqueeLabelCopy.frame = CGRectMake(-self.marqueeOffset + totalW, y, textW, self.marqueeLabel.bounds.size.height);
}

#pragma mark - Wave Animation

- (void)startWaveAnimation {
    if (self.waveLink || !self.isPlaying) return;
    self.waveLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(waveStep)];
    [self.waveLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopWaveAnimation {
    [self.waveLink invalidate];
    self.waveLink = nil;
}

- (void)waveStep {
    if (self.state != DIStateCompact && self.state != DIStateExpandedFull) return;
    CGFloat barW = (self.state == DIStateExpandedFull) ? 4.0 : 3.0;
    CGFloat barSpacing = (self.state == DIStateExpandedFull) ? 3.0 : 2.0;
    CGFloat totalW = 4 * barW + 3 * barSpacing;
    CGFloat barX, maxH;
    if (self.state == DIStateExpandedFull) {
        barX = self.bounds.size.width - 20 - totalW; maxH = 24.0;
    } else {
        barX = self.bounds.size.width - kPadding - totalW; maxH = 14.0;
    }
    CGFloat t = CACurrentMediaTime();
    for (int i = 0; i < 4; i++) {
        CGFloat phase = t * 4.0 + i * 1.2;
        CGFloat h = (maxH * 0.4) + (maxH * 0.6) * (0.5 + 0.5 * sin(phase));
        CGFloat yCenter = (self.state == DIStateExpandedFull) ? 34.0 : self.bounds.size.height / 2;
        self.waveBars[i].frame = CGRectMake(barX + i * (barW + barSpacing), yCenter - h/2, barW, h);
    }
}

#pragma mark - Public Updates

- (void)updatePlaybackState:(BOOL)playing {
    self.isPlaying = playing;
    NSString *icon = playing ? @"pause.fill" : @"play.fill";
    UIImageSymbolConfiguration *cfg14 = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
    UIImageSymbolConfiguration *cfg28 = [UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightMedium];
    [self.playPauseButton setImage:[UIImage systemImageNamed:icon withConfiguration:cfg14] forState:UIControlStateNormal];
    [self.fullPlayPauseButton setImage:[UIImage systemImageNamed:icon withConfiguration:cfg28] forState:UIControlStateNormal];

    if (playing && self.state == DIStateCompact) [self startWaveAnimation];
    else if (!playing) { [self stopWaveAnimation]; [self stopProgressLink]; }
    if (playing && self.trackDuration > 0) [self startProgressLink];
}

- (void)updateTitleDisplay {
    [self updateMarqueeText];
    self.titleLabel.text = self.titleText;
    self.artistLabel.text = self.subtitleText;
}

- (void)updateArtwork:(UIImage *)image {
    self.artworkImage = image;
    self.artworkView.image = image;
}

#pragma mark - Gestures

- (void)handleTap {
    [self.delegate contentViewDidRequestOpenApp:self];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        if (self.contentType == DIContentTypeNotification) {
            // 通知模式下长按展开/收起
            if (self.notifExpanded) [self collapseNotification];
            else [self expandNotification];
        } else {
            if (self.state == DIStateExpandedFull) [self collapseFull];
            else [self expandFull];
        }
    }
}

- (void)handleSwipeRight { if (self.state == DIStateCompact && self.contentType != DIContentTypeNotification) [self expand]; }
- (void)handleSwipeLeft {
    if (self.contentType == DIContentTypeNotification) {
        // 通知模式：左滑也立即关闭
        if ([self.delegate respondsToSelector:@selector(contentViewDidRequestDismissNotification:)]) {
            [self.delegate contentViewDidRequestDismissNotification:self];
        }
        return;
    }
    if (self.state == DIStateExpanded) [self collapse];
    else if (self.state == DIStateExpandedFull) [self collapseFull];
    else [self.delegate contentViewDidRequestDismiss:self];
}
- (void)handleSwipeUp {
    if (self.contentType == DIContentTypeNotification) {
        // 通知模式：上滑立即关闭通知
        if ([self.delegate respondsToSelector:@selector(contentViewDidRequestDismissNotification:)]) {
            [self.delegate contentViewDidRequestDismissNotification:self];
        }
        return;
    }
    [self.delegate contentViewDidRequestDismiss:self];
}
- (void)prevTapped { [self.delegate contentViewDidRequestPrevious:self]; }
- (void)playPauseTapped { [self.delegate contentViewDidRequestPlayPause:self]; }
- (void)nextTapped { [self.delegate contentViewDidRequestNext:self]; }

#pragma mark - Progress

- (void)sliderBegan:(UISlider *)slider { self.isSeeking = YES; }

- (void)sliderChanged:(UISlider *)slider {
    if (self.trackDuration > 0) {
        NSTimeInterval pos = slider.value * self.trackDuration;
        self.elapsedLabel.text = [self formatTime:pos];
        self.remainingLabel.text = [NSString stringWithFormat:@"-%@", [self formatTime:self.trackDuration - pos]];
    }
}

- (void)sliderEnded:(UISlider *)slider {
    self.isSeeking = NO;
    if (self.trackDuration > 0) {
        float position = slider.value * self.trackDuration;
        self.trackElapsed = (NSTimeInterval)position;
        [self.delegate contentViewDidRequestSeek:self toPosition:position];
        [self startProgressLink];
    }
}

- (void)updateElapsed:(NSTimeInterval)elapsed duration:(NSTimeInterval)duration {
    BOOL newTrack = (fabs(duration - self.trackDuration) > 1.0);
    self.trackDuration = duration;
    if (newTrack || self.trackElapsed == 0) self.trackElapsed = elapsed;
    if (!self.isSeeking && duration > 0 && self.isPlaying) [self startProgressLink];
}

- (void)startProgressLink {
    if (self.progressLink) return;
    self.progressLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(progressStep)];
    self.progressLink.preferredFramesPerSecond = 1;
    [self.progressLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopProgressLink {
    [self.progressLink invalidate];
    self.progressLink = nil;
}

- (void)progressStep {
    if (self.isSeeking || self.trackDuration <= 0) return;
    if (!self.isPlaying) { [self stopProgressLink]; return; }
    self.trackElapsed += 1.0;
    if (self.trackElapsed >= self.trackDuration) {
        self.trackElapsed = self.trackDuration;
        [self stopProgressLink];
    }
    self.progressSlider.value = (float)(self.trackElapsed / self.trackDuration);
    self.elapsedLabel.text = [self formatTime:self.trackElapsed];
    self.remainingLabel.text = [NSString stringWithFormat:@"-%@", [self formatTime:self.trackDuration - self.trackElapsed]];
}

- (NSString *)formatTime:(NSTimeInterval)t {
    int mins = (int)t / 60;
    int secs = (int)t % 60;
    return [NSString stringWithFormat:@"%d:%02d", mins, secs];
}

#pragma mark - Notification Display

- (void)showNotificationWithTitle:(NSString *)title message:(NSString *)message icon:(UIImage *)icon {
    self.contentType = DIContentTypeNotification;
    self.notifExpanded = NO;
    [self stopNotifMarquee];
    self.notifTitleLabel.text = title ?: DILocalizedString(@"DI_NOTIFICATION_FALLBACK");
    self.notifMessageLabel.text = message ?: @"";
    if (icon) self.notifIconView.image = icon;

    // 隐藏音乐相关视图
    self.marqueeContainer.hidden = YES;
    for (CALayer *bar in self.waveBars) bar.hidden = YES;
    self.prevButton.hidden = YES; self.playPauseButton.hidden = YES; self.nextButton.hidden = YES;
    self.fullControlsView.hidden = YES;
    self.artworkView.hidden = YES;

    // 显示通知容器
    self.notificationContainer.hidden = NO;

    CGRect superBounds = self.superview.bounds;
    CGFloat notifW = _prefExpandedW;
    CGFloat notifH = _prefCompactH + 8;

    BOOL wasHidden = (self.state == DIStateHidden);
    self.state = DIStateCompact;

    if (wasHidden) {
        // 从隐藏状态弹出
        self.transform = CGAffineTransformIdentity;
        self.frame = CGRectMake((superBounds.size.width - notifW) / 2, _prefYOffset, notifW, notifH);
        self.layer.cornerRadius = _prefNotifCorner;
        self.transform = CGAffineTransformMakeScale(0.8, 0.8);
        self.alpha = 0;

        [UIView animateWithDuration:0.5 delay:0
             usingSpringWithDamping:0.7 initialSpringVelocity:0.8
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.alpha = 1.0;
            self.transform = CGAffineTransformIdentity;
        } completion:nil];
    } else {
        // 从音乐岛切换到通知岛（变形动画）
        [UIView animateWithDuration:0.35 delay:0
             usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:^{
            self.transform = CGAffineTransformIdentity;
            self.frame = CGRectMake((superBounds.size.width - notifW) / 2, _prefYOffset, notifW, notifH);
        } completion:nil];
    }

    // 通知容器布局
    [self layoutNotificationContent];

    // 淡入通知内容
    [UIView animateWithDuration:0.2 animations:^{
        self.notificationContainer.alpha = 1.0;
    } completion:^(BOOL f) {
        [self startNotifMarqueeIfNeeded];
    }];
}

- (void)layoutNotificationContent {
    CGRect b = self.bounds;

    if (self.notifExpanded) {
        // 展开模式：系统横幅大小，完整标题+多行消息
        CGFloat iconS = 32;
        CGFloat pad = 12;
        self.notifIconView.frame = CGRectMake(pad, pad, iconS, iconS);

        CGFloat textX = pad + iconS + 10;
        CGFloat textW = b.size.width - textX - pad;
        self.notifTitleLabel.frame = CGRectMake(textX, pad, textW, 18);
        self.notifTitleLabel.numberOfLines = 1;

        // 多行消息
        self.notifMessageLabel.hidden = NO;
        self.notifMessageLabel.numberOfLines = 0;
        self.notifMessageLabel.lineBreakMode = NSLineBreakByWordWrapping;
        CGFloat msgY = pad + 18 + 4;
        CGFloat msgMaxH = b.size.height - msgY - pad;
        CGSize msgSize = [self.notifMessageLabel sizeThatFits:CGSizeMake(textW, msgMaxH)];
        self.notifMessageLabel.frame = CGRectMake(textX, msgY, textW, MIN(msgSize.height, msgMaxH));

        // 隐藏滚动容器
        self.notifMsgMarqueeContainer.hidden = YES;
    } else {
        // 紧凑模式
        CGFloat iconS = 26;
        CGFloat iconY = (b.size.height - iconS) / 2;
        self.notifIconView.frame = CGRectMake(kPadding + 2, iconY, iconS, iconS);

        CGFloat textX = kPadding + iconS + 10;
        CGFloat textW = b.size.width - textX - kPadding;
        CGFloat titleH = 16, msgH = 14;
        CGFloat totalH = titleH + msgH + 2;
        CGFloat textY = (b.size.height - totalH) / 2;
        self.notifTitleLabel.frame = CGRectMake(textX, textY, textW, titleH);
        self.notifTitleLabel.numberOfLines = 1;

        // 检查消息是否需要滚动
        NSString *msg = self.notifMessageLabel.text ?: @"";
        CGSize msgSize = [msg sizeWithAttributes:@{NSFontAttributeName: self.notifMessageLabel.font}];
        if (msgSize.width > textW && msg.length > 0) {
            // 使用滚动容器
            self.notifMessageLabel.hidden = YES;
            self.notifMsgMarqueeContainer.hidden = NO;
            self.notifMsgMarqueeContainer.frame = CGRectMake(textX, textY + titleH + 2, textW, msgH);
            [self setupNotifMarqueeWithText:msg containerWidth:textW height:msgH];
        } else {
            self.notifMessageLabel.hidden = NO;
            self.notifMessageLabel.numberOfLines = 1;
            self.notifMessageLabel.lineBreakMode = NSLineBreakByTruncatingTail;
            self.notifMessageLabel.frame = CGRectMake(textX, textY + titleH + 2, textW, msgH);
            self.notifMsgMarqueeContainer.hidden = YES;
        }
    }

    self.notificationContainer.frame = b;
}

- (void)expandNotification {
    if (self.notifExpanded) return;
    self.notifExpanded = YES;
    [self.feedbackGenerator impactOccurred];
    [self stopNotifMarquee];

    // 通知 delegate 暂停自动消失 timer
    if ([self.delegate respondsToSelector:@selector(contentViewDidExpandNotification:)]) {
        [self.delegate contentViewDidExpandNotification:self];
    }

    CGFloat screenW = self.superview.bounds.size.width;
    // 系统横幅大小：宽度接近屏幕宽，高度根据消息内容自适应
    CGFloat expandedW = screenW - 20;
    CGFloat expandedH = 90; // 默认高度，足够显示多行

    // 根据消息内容计算高度
    NSString *msg = self.notifMessageLabel.text ?: @"";
    if (msg.length > 0) {
        CGFloat textW = expandedW - 32 - 10 - 12 - 12; // icon + gaps + padding
        CGSize msgSize = [msg boundingRectWithSize:CGSizeMake(textW, 200)
                                           options:NSStringDrawingUsesLineFragmentOrigin
                                        attributes:@{NSFontAttributeName: self.notifMessageLabel.font}
                                           context:nil].size;
        expandedH = MAX(90, 12 + 18 + 4 + msgSize.height + 12);
        expandedH = MIN(expandedH, 160); // 最大高度限制
    }

    CGRect targetFrame = CGRectMake((screenW - expandedW) / 2, _prefYOffset, expandedW, expandedH);

    [UIView animateWithDuration:0.4 delay:0
         usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.frame = targetFrame;
        self.layer.cornerRadius = _prefNotifCorner;
    } completion:^(BOOL finished) {
        [self setNeedsLayout];
        [self layoutIfNeeded];
    }];
}

- (void)collapseNotification {
    if (!self.notifExpanded) return;
    self.notifExpanded = NO;

    // 通知 delegate 恢复自动消失 timer
    if ([self.delegate respondsToSelector:@selector(contentViewDidCollapseNotification:)]) {
        [self.delegate contentViewDidCollapseNotification:self];
    }

    CGFloat screenW = self.superview.bounds.size.width;
    CGFloat notifW = _prefExpandedW;
    CGFloat notifH = _prefCompactH + 8;
    CGRect targetFrame = CGRectMake((screenW - notifW) / 2, _prefYOffset, notifW, notifH);

    [UIView animateWithDuration:0.35 delay:0
         usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.frame = targetFrame;
        self.layer.cornerRadius = _prefNotifCorner;
    } completion:^(BOOL finished) {
        [self setNeedsLayout];
        [self layoutIfNeeded];
        [self startNotifMarqueeIfNeeded];
    }];
}

#pragma mark - Notification Message Marquee

- (void)setupNotifMarqueeWithText:(NSString *)text containerWidth:(CGFloat)containerW height:(CGFloat)height {
    self.notifMsgMarqueeLabel.text = text;
    self.notifMsgMarqueeLabelCopy.text = text;
    [self.notifMsgMarqueeLabel sizeToFit];
    [self.notifMsgMarqueeLabelCopy sizeToFit];

    CGFloat textW = self.notifMsgMarqueeLabel.bounds.size.width;
    CGFloat labelY = (height - self.notifMsgMarqueeLabel.bounds.size.height) / 2;
    self.notifMsgMarqueeLabel.frame = CGRectMake(0, labelY, textW, self.notifMsgMarqueeLabel.bounds.size.height);

    if (textW > containerW) {
        CGFloat gap = 40;
        self.notifMsgMarqueeLabelCopy.hidden = NO;
        self.notifMsgMarqueeLabelCopy.frame = CGRectMake(textW + gap, labelY, textW, self.notifMsgMarqueeLabel.bounds.size.height);
        self.notifMarqueeOffset = 0;
        [self startNotifMarquee];
    } else {
        self.notifMsgMarqueeLabelCopy.hidden = YES;
        [self stopNotifMarquee];
    }
}

- (void)startNotifMarqueeIfNeeded {
    if (self.contentType != DIContentTypeNotification) return;
    if (self.notifExpanded) return;
    if (self.notifMsgMarqueeContainer.hidden) return;
    CGFloat textW = self.notifMsgMarqueeLabel.bounds.size.width;
    CGFloat containerW = self.notifMsgMarqueeContainer.bounds.size.width;
    if (textW > containerW) [self startNotifMarquee];
}

- (void)startNotifMarquee {
    if (self.notifMarqueeLink) return;
    self.notifMarqueeLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(notifMarqueeStep)];
    [self.notifMarqueeLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopNotifMarquee {
    [self.notifMarqueeLink invalidate];
    self.notifMarqueeLink = nil;
}

- (void)notifMarqueeStep {
    CGFloat textW = self.notifMsgMarqueeLabel.bounds.size.width;
    CGFloat containerW = self.notifMsgMarqueeContainer.bounds.size.width;
    if (textW <= containerW) return;
    CGFloat gap = 40, speed = 0.5;
    self.notifMarqueeOffset += speed;
    CGFloat totalW = textW + gap;
    if (self.notifMarqueeOffset >= totalW) self.notifMarqueeOffset = 0;
    CGFloat y = self.notifMsgMarqueeLabel.frame.origin.y;
    self.notifMsgMarqueeLabel.frame = CGRectMake(-self.notifMarqueeOffset, y, textW, self.notifMsgMarqueeLabel.bounds.size.height);
    self.notifMsgMarqueeLabelCopy.frame = CGRectMake(-self.notifMarqueeOffset + totalW, y, textW, self.notifMsgMarqueeLabel.bounds.size.height);
}

- (void)hideNotification {
    [self stopNotifMarquee];
    self.notifExpanded = NO;
    [UIView animateWithDuration:0.25 animations:^{
        self.alpha = 0.0;
        self.transform = CGAffineTransformMakeScale(0.8, 0.8);
    } completion:^(BOOL f) {
        self.state = DIStateHidden;
        self.contentType = DIContentTypeMedia;
        self.notificationContainer.hidden = YES;
        self.notificationContainer.alpha = 0;
        self.notifMsgMarqueeContainer.hidden = YES;
        self.artworkView.hidden = NO;
    }];
}

- (void)hideNotificationImmediate {
    [self stopNotifMarquee];
    self.notifExpanded = NO;
    // 立即清空通知容器，避免和音乐岛重叠
    self.notificationContainer.hidden = YES;
    self.notificationContainer.alpha = 0;
    self.notifMsgMarqueeContainer.hidden = YES;
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = 0.0;
        self.transform = CGAffineTransformMakeScale(0.8, 0.8);
    } completion:^(BOOL f) {
        self.state = DIStateHidden;
        self.contentType = DIContentTypeMedia;
        self.artworkView.hidden = NO;
    }];
}

- (void)switchToMedia {
    [self stopNotifMarquee];
    self.notifExpanded = NO;
    // 淡出通知内容
    [UIView animateWithDuration:0.2 animations:^{
        self.notificationContainer.alpha = 0;
    } completion:^(BOOL f) {
        self.notificationContainer.hidden = YES;
        self.notifMsgMarqueeContainer.hidden = YES;
        self.contentType = DIContentTypeMedia;
        self.artworkView.hidden = NO;
        self.marqueeContainer.hidden = NO;

        // 恢复音乐岛紧凑模式
        self.state = DIStateCompact;
        CGRect superBounds = self.superview.bounds;
        [UIView animateWithDuration:0.35 delay:0
             usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:^{
            self.frame = CGRectMake((superBounds.size.width - _prefCompactW) / 2, _prefYOffset, _prefCompactW, _prefCompactH);
            self.layer.cornerRadius = _prefMediaCorner;
        } completion:^(BOOL finished) {
            [self updateMarqueeText];
            [self startMarquee];
            [self startWaveAnimation];
            [self setNeedsLayout];
            [self layoutIfNeeded];
        }];
    }];
}

@end
