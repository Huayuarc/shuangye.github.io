#import "CPUthermalCC1x1ModuleViewController.h"
#import <Foundation/Foundation.h>
#import <notify.h>
#import <QuartzCore/QuartzCore.h>
#import <CPUthermalPaths.h>

// ============================================================
// 注意: 禁止使用 @"" ObjC 字符串常量
// roothide 重映射会破坏 __cfstring 内部指针，导致 SIGBUS
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================

// 与 2×1 模块图标同尺寸（避免 1×1 图标过大）
static const CGFloat kCCTinyGlyphPointSize = 24.0;
// 与控制中心小尺寸模块 platter 一致的圆角
static const CGFloat kCCTinyHighlightCornerRadius = 15.0;

@interface CPUthermalCC1x1ModuleViewController ()
@property (nonatomic, strong) UIView *highlightView;
@property (nonatomic, strong) UIImageView *glyphView;
@end

@implementation CPUthermalCC1x1ModuleViewController

//==============================================================================
#pragma mark - Prefs Helpers
//==============================================================================

- (NSString *)currentPowerMode {
    NSDictionary *prefs = CPUthermalReadPrefs();
    NSString *mode = prefs[S("powerMode")];
    if ([mode isKindOfClass:[NSString class]] && [mode length] > 0) {
        return mode;
    }
    return S(kCPUthermalFullPowerModeC);
}

- (BOOL)isLowPower {
    return [[self currentPowerMode] isEqualToString:S(kCPUthermalLowPowerModeC)];
}

- (BOOL)isHighPerformance {
    return ![self isLowPower];
}

/// 写入运行方式并通知（与 2×1 模块、设置面板共用同一偏好键与通知）
- (void)savePowerMode:(NSString *)mode {
    NSMutableDictionary *prefs = CPUthermalReadMutablePrefs();
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    prefs[S("powerMode")] = mode ?: S(kCPUthermalFullPowerModeC);
    CPUthermalWritePrefs(prefs);
    CPUthermalPostPowerMode(mode ?: S(kCPUthermalFullPowerModeC));
}

//==============================================================================
#pragma mark - Lifecycle
//==============================================================================

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    // 高亮底板：仅在“解除温控”时显示（低功耗保持与控制中心普通模块一致的背景）
    self.highlightView = [[UIView alloc] initWithFrame:CGRectZero];
    self.highlightView.userInteractionEnabled = NO;
    self.highlightView.layer.cornerRadius = kCCTinyHighlightCornerRadius;
    self.highlightView.layer.cornerCurve = kCACornerCurveContinuous;
    self.highlightView.hidden = YES;
    [self.view addSubview:self.highlightView];

    // 图标：与 2×1 模块同尺寸（24pt），不再放大
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:kCCTinyGlyphPointSize
                                                        weight:UIImageSymbolWeightSemibold];
    UIImage *glyphImage = [UIImage systemImageNamed:S("thermometer.sun.fill") withConfiguration:config];

    self.glyphView = [[UIImageView alloc] initWithImage:glyphImage];
    self.glyphView.contentMode = UIViewContentModeCenter;
    self.glyphView.userInteractionEnabled = NO;
    [self.view addSubview:self.glyphView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    [self.view addGestureRecognizer:tap];

    [self registerSettingsObserver];
    [self refreshUI];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshUI];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGRect bounds = self.view.bounds;
    if (CGRectGetWidth(bounds) <= 0.0 || CGRectGetHeight(bounds) <= 0.0) return;

    self.highlightView.frame = bounds;
    self.glyphView.frame = bounds;   // 图标始终居中（contentMode = Center，不放大）
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self updateHighlightAppearance];
}

//==============================================================================
#pragma mark - State
//==============================================================================

- (void)updateHighlightAppearance {
    BOOL dark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    // 与 2×1 模块“高亮（白色 platter）”观感一致；深色模式下使用低透明度白，避免刺眼
    self.highlightView.backgroundColor = dark
        ? [UIColor colorWithWhite:1.0 alpha:0.16]
        : [UIColor colorWithWhite:1.0 alpha:0.95];
}

- (void)refreshUI {
    BOOL lowPower = [self isLowPower];
    self.glyphView.tintColor = lowPower ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];

    [self updateHighlightAppearance];
    // 只有“解除温控”显示启用高亮；低功耗为普通背景
    self.highlightView.hidden = lowPower;
}

// 控制中心若查询选中态：高亮仅在“解除温控”时返回 YES
- (BOOL)isSelected {
    return [self isHighPerformance];
}

- (void)registerSettingsObserver {
    static int token = 0;
    static BOOL registered = NO;
    if (registered) return;
    registered = YES;
    __weak typeof(self) weakSelf = self;
    notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &token, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        [weakSelf refreshUI];
    });
}

- (void)handleTap {
    // 点按在两种运行方式之间切换（低功耗 <-> 解除温控）
    NSString *next = [self isLowPower] ? S(kCPUthermalFullPowerModeC) : S(kCPUthermalLowPowerModeC);
    [self savePowerMode:next];
    [self refreshUI];
}

//==============================================================================
#pragma mark - CCUIContentModuleContentViewController
//==============================================================================

- (CGFloat)preferredExpandedContentHeight {
    return 120.0;
}

- (BOOL)providesOwnPlatter {
    return NO;
}

- (BOOL)shouldBeginTransitionToExpandedContentModule {
    // 1×1 模块不展开，点按即切换
    return NO;
}

@end
