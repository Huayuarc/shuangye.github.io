#import "CPUthermalHighPerformanceCCModule.h"
#import <CPUthermalPaths.h>
#import <notify.h>

@interface CPUthermalHighPerformanceCCModuleViewController ()
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) UIImageView *glyphView;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *stateLabel;
@end

@implementation CPUthermalHighPerformanceCCModuleViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.clipsToBounds = NO;
    _button = [UIButton buttonWithType:UIButtonTypeCustom];
    _button.frame = self.view.bounds;
    _button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_button addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_button];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
    _glyphView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:S("bolt.fill") withConfiguration:config]];
    _glyphView.contentMode = UIViewContentModeScaleAspectFit;
    [_button addSubview:_glyphView];
    _titleLabel = [UILabel new];
    _titleLabel.text = S("高性能");
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.62;
    [_button addSubview:_titleLabel];
    _stateLabel = [UILabel new];
    _stateLabel.textAlignment = NSTextAlignmentCenter;
    _stateLabel.adjustsFontSizeToFitWidth = YES;
    _stateLabel.minimumScaleFactor = 0.68;
    [_button addSubview:_stateLabel];
    [self refreshState];
}
- (BOOL)isEnabled {
    id value = CPUthermalReadPrefs()[S("highPerformanceModeEnabled")];
    return value ? [value boolValue] : NO;
}
- (BOOL)isLowPowerMode {
    id value = CPUthermalReadPrefs()[S("powerMode")];
    return [value isKindOfClass:[NSString class]] && [value isEqualToString:S(kCPUthermalLowPowerModeC)];
}
- (void)toggle:(id)sender {
    BOOL enabled = ![self isEnabled];
    NSMutableDictionary *prefs = CPUthermalReadMutablePrefs() ?: [NSMutableDictionary dictionary];
    prefs[S("highPerformanceModeEnabled")] = [NSNumber numberWithBool:enabled];
    CPUthermalWritePrefs(prefs);
    notify_post(kCPUthermalSettingsChangedNotifC);
    [self refreshState];
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];
}
- (void)refreshState {
    BOOL enabled = [self isEnabled];
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
    UIImage *baseGlyph = [UIImage systemImageNamed:S("bolt.fill") withConfiguration:configuration];
    UIColor *glyphColor = enabled ? [UIColor systemOrangeColor] : [UIColor colorWithWhite:1.0 alpha:0.72];
    _glyphView.image = [baseGlyph imageWithTintColor:glyphColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    _titleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:enabled ? 1.0 : 0.82];
    _stateLabel.textColor = [UIColor colorWithWhite:1.0 alpha:enabled ? 0.75 : 0.58];
    _stateLabel.text = enabled ? ([self isLowPowerMode] ? S("低功耗待命") : S("已启用")) : S("已关闭");
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refreshState]; [self.view setNeedsLayout]; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds; CGFloat w = CGRectGetWidth(bounds), h = CGRectGetHeight(bounds);
    _button.frame = bounds; BOOL compact = (w < 150.0 && h < 150.0);
    CGFloat icon = compact ? 24.0 : 38.0, titleH = compact ? 15.0 : 24.0, stateH = compact ? 12.0 : 19.0, gap = compact ? 2.0 : 7.0;
    CGFloat y = floor(MAX(compact ? 5.0 : 10.0, (h - icon - gap - titleH - stateH) / 2.0));
    CGFloat inset = compact ? 3.0 : 18.0;
    _glyphView.frame = CGRectIntegral(CGRectMake((w-icon)/2.0, y, icon, icon)); y += icon + gap;
    _titleLabel.frame = CGRectIntegral(CGRectMake(inset, y, MAX(0,w-inset*2), titleH)); y += titleH;
    _stateLabel.frame = CGRectIntegral(CGRectMake(inset, y, MAX(0,w-inset*2), stateH));
    _titleLabel.font = [UIFont systemFontOfSize:compact ? 10.0 : 16.0 weight:UIFontWeightSemibold];
    _stateLabel.font = [UIFont systemFontOfSize:compact ? 8.0 : 12.0 weight:UIFontWeightRegular];
}
- (BOOL)shouldBeginTransitionToExpandedContentModule { return YES; }
- (void)willTransitionToExpandedContentMode:(BOOL)animated { [self refreshState]; [self.view setNeedsLayout]; }
- (void)willReturnToExpandedContentModule { [self refreshState]; [self.view setNeedsLayout]; }
- (CGFloat)preferredExpandedContentHeight { return 180.0; }
- (CGFloat)preferredExpandedContentWidth { CGFloat w = CGRectGetWidth([UIScreen mainScreen].bounds)-48.0; return MIN(MAX(w,240.0),340.0); }
- (BOOL)providesOwnPlatter { return NO; }
@end
