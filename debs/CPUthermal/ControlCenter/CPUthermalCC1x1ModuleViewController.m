#import "CPUthermalCC1x1ModuleViewController.h"
#import <Foundation/Foundation.h>
#import <notify.h>
#import <CPUthermalPaths.h>

// ============================================================
// 注意: 禁止使用 @"" ObjC 字符串常量
// roothide 重映射会破坏 __cfstring 内部指针，导致 SIGBUS
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================

static const CGFloat kCCTinyGlyphPointSize = 26.0;
static const CGFloat kCCTinyTitleFontSize = 11.0;

@interface CPUthermalCC1x1ModuleViewController ()
@property (nonatomic, strong) UIImageView *glyphView;
@property (nonatomic, strong) UILabel *stateLabel;
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

/// 写入运行方式并通知（与 2×1 模块、面板共用同一偏好键与通知）
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

- (instancetype)init {
    self = [super init];
    if (self) {
        _glyphView = nil;
        _stateLabel = nil;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:kCCTinyGlyphPointSize
                                                        weight:UIImageSymbolWeightSemibold];
    UIImage *glyphImage = [UIImage systemImageNamed:S("thermometer.sun.fill") withConfiguration:config];

    self.glyphView = [[UIImageView alloc] initWithImage:glyphImage];
    self.glyphView.contentMode = UIViewContentModeScaleAspectFit;
    self.glyphView.userInteractionEnabled = NO;
    [self.view addSubview:self.glyphView];

    self.stateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.stateLabel.font = [UIFont systemFontOfSize:kCCTinyTitleFontSize weight:UIFontWeightSemibold];
    self.stateLabel.textAlignment = NSTextAlignmentCenter;
    self.stateLabel.numberOfLines = 1;
    self.stateLabel.adjustsFontSizeToFitWidth = YES;
    self.stateLabel.minimumScaleFactor = 0.75;
    [self.view addSubview:self.stateLabel];

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
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width <= 0.0 || height <= 0.0) return;

    CGFloat labelHeight = 15.0;
    CGFloat glyphSide = MIN(width * 0.58, height - labelHeight - 4.0);
    if (glyphSide < 18.0) glyphSide = MAX(18.0, height * 0.5);

    CGFloat glyphTop = (height - glyphSide - labelHeight) * 0.5;
    if (glyphTop < 2.0) glyphTop = 2.0;

    self.glyphView.frame = CGRectMake((width - glyphSide) * 0.5, glyphTop, glyphSide, glyphSide);
    self.stateLabel.frame = CGRectMake(2.0, CGRectGetMaxY(self.glyphView.frame) + 1.0, width - 4.0, labelHeight);
}

//==============================================================================
#pragma mark - State
//==============================================================================

- (void)refreshUI {
    BOOL lowPower = [self isLowPower];
    self.stateLabel.text = lowPower ? S("低功耗") : S("高性能");
    UIColor *tint = lowPower ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
    self.glyphView.tintColor = tint;
    self.stateLabel.textColor = tint;
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
    // 点按在两种运行方式之间切换（低功耗 <-> 稳定高性能）
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
