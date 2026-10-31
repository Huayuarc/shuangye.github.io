#import "CPUthermalCCModuleViewController.h"
#import <notify.h>
#import <Foundation/Foundation.h>
#import <spawn.h>
#import <CPUthermalPaths.h>

// ============================================================
// 注意: 禁止使用 @"" ObjC 字符串常量
// roothide 重映射会破坏 __cfstring 内部指针，导致 SIGBUS
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================

@interface CPUthermalCCModuleViewController ()
@property (nonatomic, assign) int settingsObserverToken;
@property (nonatomic, assign) BOOL settingsObserverRegistered;
- (void)updateSelectedIndexFromCurrentMode;
- (BOOL)isTweakEnabled;
- (void)saveTweakEnabled:(BOOL)enabled;
- (void)toggleTweakEnabled;
- (void)updateModuleSelectedState;
- (void)selectPowerModeAtIndex:(NSInteger)index;
- (void)selectPowerModeAtIndex:(NSInteger)index dismissAfterSelection:(BOOL)dismissAfterSelection;
- (CGFloat)availableExpandedContentWidth;
@end

static const CGFloat kCPUthermalCCPreferredExpandedWidth = 320.0;
static const CGFloat kCPUthermalCCPreferredExpandedHeight = 236.0;   // 头部 + 2 行（标题+副标题），按实际行数计算
static const CGFloat kCPUthermalCCMinimumScreenMargin = 30.0;
static const CGFloat kCPUthermalCCHeaderHeight = 96.0;
static const CGFloat kCPUthermalCCMenuRowHeight = 66.0;

@interface UIView (CPUthermalCCPrivateLayout)
- (UILabel *)titleLabel;
- (UILabel *)subtitleLabel;
- (UIView *)contentView;
- (void)setUseTrailingCheckmarkLayout:(BOOL)useTrailingCheckmarkLayout;
- (void)setUseTrailingInset:(BOOL)useTrailingInset;
- (void)setIndentation:(CGFloat)indentation;
@end

@implementation CPUthermalCCModuleViewController

@synthesize modeValues = _modeValues;
@synthesize modeTitles = _modeTitles;
@synthesize modeSubtitles = _modeSubtitles;
@synthesize selectedIndex = _selectedIndex;

//==============================================================================
#pragma mark - Prefs Helpers
//==============================================================================


/// 读取当前功率模式值
- (NSString *)currentPowerMode {
    NSDictionary *prefs = CPUthermalReadPrefsSnapshot();
    NSString *mode = prefs[S("powerMode")];
    if ([mode isKindOfClass:[NSString class]] && [mode length] > 0) {
        return mode;
    }
    return S(kCPUthermalFullPowerModeC); // 默认解除温控
}

- (BOOL)isTweakEnabled {
    return YES; // 始终启用，无需用户开关
}

- (void)saveTweakEnabled:(BOOL)enabled {
    // 已废弃：CPUthermal 始终启用，无需保存开关状态
}

/// 写入功率模式并发送通知
- (void)savePowerMode:(NSString *)mode {
    NSMutableDictionary *prefs = CPUthermalReadMutablePrefs();
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    prefs[S("powerMode")] = mode ?: S(kCPUthermalFullPowerModeC);

    CPUthermalWritePrefs(prefs);
    CPUthermalPostPowerMode(mode ?: S(kCPUthermalFullPowerModeC));
}


//==============================================================================
#pragma mark - Initialization
//==============================================================================

- (instancetype)init {
    self = [super init];
    if (self) {
        _modeValues = @[S(kCPUthermalLowPowerModeC), S(kCPUthermalFullPowerModeC)];
        _modeTitles = @[S("低功耗"), S("解除温控")];
        _modeSubtitles = @[S("降频降功耗，不动亮度"), S("拦截热降频，原生调频")];

        // 读取当前设置的模式
        NSString *currentMode = [self currentPowerMode];
        _selectedIndex = [_modeValues indexOfObject:currentMode];
        if (_selectedIndex == NSNotFound) {
            _selectedIndex = [_modeValues indexOfObject:S(kCPUthermalFullPowerModeC)];
        }
    }
    return self;
}

//==============================================================================
#pragma mark - UIViewController Lifecycle
//==============================================================================

- (void)viewDidLoad {
    [super viewDidLoad];

    // 设置标题
    self.title = S("CPUthermal");

    // 设置控制中心图标（用 respondsToSelector 保护，避免私有 API 变更导致崩溃）
    // 初始图标按当前模式预着色（低功耗绿 / 解除温控橙），与 1×1 一致
    BOOL initialHighPerformance = [[self currentPowerMode] isEqualToString:S(kCPUthermalFullPowerModeC)];
    UIImage *glyphImage = [self glyphImageForHighPerformance:initialHighPerformance];
    if (glyphImage && [self respondsToSelector:@selector(setGlyphImage:)]) {
        [self setGlyphImage:glyphImage];
    }
    if ([self respondsToSelector:@selector(setSelectedGlyphColor:)]) {
        [self setSelectedGlyphColor:[UIColor systemOrangeColor]];
    }

    if ([self respondsToSelector:@selector(setUseTrailingCheckmarkLayout:)]) {
        [self setUseTrailingCheckmarkLayout:YES];
    }
    if ([self respondsToSelector:@selector(setUseTallLayout:)]) {
        [self setUseTallLayout:YES];   // 宽行：标题+副标题都有位置，不再挤压
    }
    if ([self respondsToSelector:@selector(setHideGlyphInHeader:)]) {
        [self setHideGlyphInHeader:NO];
    }
    if ([self respondsToSelector:@selector(setShouldProvideOwnPlatter:)]) {
        [self setShouldProvideOwnPlatter:NO];
    }

    // 布局 UI
    [self setupView];
    [self updateModeTitle];
    [self registerSettingsObserver];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshState];
    [self updateModeTitle];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Native Control Center layout only; no recursive restyling.
}

//==============================================================================
#pragma mark - Public
//==============================================================================

- (void)refreshState {
    [self updateSelectedIndexFromCurrentMode];
    [self setupModeButtons];
    [self updateModuleSelectedState];
    [self updateModeTitle];
}

// 折叠态（尤其 2×1 宽模块）显示“图标 + 当前模式文字”，而不是只显示图标。
- (void)updateModeTitle {
    NSString *currentMode = [self currentPowerMode];
    NSString *title = [currentMode isEqualToString:S(kCPUthermalLowPowerModeC)] ? S("低功耗") : S("解除温控");
    self.title = title;
}

// 偏好变化（面板/控制中心切换）后立即刷新标题与选中态
- (void)registerSettingsObserver {
    if (self.settingsObserverRegistered) return;
    __weak typeof(self) weakSelf = self;
    int token = -1;
    uint32_t status = notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &token,
                                               dispatch_get_main_queue(), ^(int t) {
        (void)t;
        [weakSelf refreshState];
    });
    if (status == NOTIFY_STATUS_OK) {
        self.settingsObserverToken = token;
        self.settingsObserverRegistered = YES;
    }
}

- (void)dealloc {
    if (_settingsObserverRegistered) notify_cancel(_settingsObserverToken);
}

//==============================================================================
#pragma mark - CCUIContentModuleContentViewController
//==============================================================================

- (BOOL)shouldBeginTransitionToExpandedContentModule {
    return YES;
}

- (void)willTransitionToExpandedContentMode:(BOOL)animated {
    [super willTransitionToExpandedContentMode:animated];
    // 展开时刷新菜单
    [self refreshState];
}

- (CGFloat)preferredExpandedContentHeight {
    // 按实际模式数量计算：头部（图标+标题）+ 每行（标题+副标题），
    // 避免长按展开后被裁掉（此前固定 250 导致第三项被截断）。
    CGFloat rows = (CGFloat)MAX((NSUInteger)1, MIN(self.modeValues.count, self.modeTitles.count));
    CGFloat height = kCPUthermalCCHeaderHeight + rows * kCPUthermalCCMenuRowHeight;
    // 取计算值与基准值的较大者：2 档时约 96 + 2×68 = 232，避免底部多出一大块空白
    return MAX(kCPUthermalCCPreferredExpandedHeight, height);
}

- (CGFloat)preferredExpandedContentWidth {
    return [self availableExpandedContentWidth];
}

- (BOOL)providesOwnPlatter {
    return NO;
}


//==============================================================================
#pragma mark - Setup
//==============================================================================

- (void)setupView {
    [self updateSelectedIndexFromCurrentMode];

    // 设置菜单项
    [self setupModeButtons];

    // 应用当前选中状态
    [self updateModuleSelectedState];
}

- (void)setupModeButtons {
    NSString *currentMode = [self currentPowerMode];
    BOOL isFullPower = [currentMode isEqualToString:S(kCPUthermalFullPowerModeC)];
    NSUInteger itemCount = MIN(self.modeValues.count, self.modeTitles.count);

    NSMutableArray *items = [NSMutableArray arrayWithCapacity:itemCount];
    for (NSUInteger i = 0; i < itemCount; i++) {
        NSString *title = self.modeTitles[i];
        BOOL isSelected = ((NSInteger)i == self.selectedIndex);
        NSString *subtitle = i < self.modeSubtitles.count ? self.modeSubtitles[i] : S("");

        NSString *identifier = S("cpu-item-");
        identifier = [identifier stringByAppendingFormat:S("%lu"), (unsigned long)i];
        __weak typeof(self) weakSelf = self;
        NSInteger itemIndex = (NSInteger)i;
        CCUIMenuModuleItem *item = [[CCUIMenuModuleItem alloc] initWithTitle:title identifier:identifier handler:^{
            [weakSelf selectPowerModeAtIndex:itemIndex];
        }];
        if (!item) {
            continue;
        }
        if ([item respondsToSelector:@selector(setSubtitle:)]) {
            [item setSubtitle:subtitle];
        }
        if ([item respondsToSelector:@selector(setSelected:)]) {
            [item setSelected:isSelected];
        }

        // 根据模式设置选中状态和颜色（用 respondsToSelector 保护私有 API）
        if (isSelected) {
            if ([item respondsToSelector:@selector(setSelectedGlyphColor:)]) {
                if (isFullPower) {
                    [item setSelectedGlyphColor:[UIColor systemOrangeColor]];
                } else {
                    [item setSelectedGlyphColor:[UIColor systemGreenColor]];
                }
            }
        }

        [items addObject:item];
    }

    if ([self respondsToSelector:@selector(setMinimumMenuItems:)]) {
        [self setMinimumMenuItems:(NSInteger)itemCount];
    }
    if ([self respondsToSelector:@selector(setVisibleMenuItems:)]) {
        [self setVisibleMenuItems:(NSInteger)itemCount];
    }

    // 父类 setMenuItems: 有 respondsToSelector 兜底
    if ([self respondsToSelector:@selector(setMenuItems:)]) {
        self.menuItems = items;
    }

    // Native Control Center layout only; no recursive restyling.
}

- (CGFloat)availableExpandedContentWidth {
    CGFloat width = kCPUthermalCCPreferredExpandedWidth;
    UIScreen *screen = [UIScreen mainScreen];
    CGFloat screenWidth = CGRectGetWidth(screen.bounds);
    if (screenWidth > 0) {
        width = MIN(width, screenWidth - (kCPUthermalCCMinimumScreenMargin * 2.0));
    }
    return MAX(width, 220.0);
}

//==============================================================================
#pragma mark - Button Actions
//==============================================================================

- (void)updateSelectedIndexFromCurrentMode {
    NSString *currentMode = [self currentPowerMode];
    NSInteger newIndex = [self.modeValues indexOfObject:currentMode];
    if (newIndex == NSNotFound) {
        newIndex = [self.modeValues indexOfObject:S(kCPUthermalFullPowerModeC)];
    }
    _selectedIndex = newIndex;
}

- (void)buttonTapped:(id)arg forEvent:(id)event {
    (void)arg;
    (void)event;

    [self updateSelectedIndexFromCurrentMode];
    NSInteger itemCount = (NSInteger)self.modeValues.count;
    if (itemCount <= 0) {
        return;
    }

    NSInteger nextIndex = (self.selectedIndex + 1) % itemCount;
    [self selectPowerModeAtIndex:nextIndex dismissAfterSelection:NO];
}

- (void)toggleTweakEnabled {
    // 已废弃：CPUthermal 始终启用，无需切换
}

- (void)buttonModeTapped:(CCUIMenuModuleItem *)sender {
    NSInteger index = [self.menuItems indexOfObject:sender];
    [self selectPowerModeAtIndex:index];
}

- (void)selectPowerModeAtIndex:(NSInteger)index {
    [self selectPowerModeAtIndex:index dismissAfterSelection:YES];
}

- (void)selectPowerModeAtIndex:(NSInteger)index dismissAfterSelection:(BOOL)dismissAfterSelection {
    if (index == NSNotFound || index < 0 || index >= (NSInteger)self.modeValues.count) {
        return;
    }

    _selectedIndex = index;
    NSString *modeValue = self.modeValues[index];

    // 写入偏好设置并通知 tweak
    [self savePowerMode:modeValue];

    // 刷新 UI
    [self setupModeButtons];
    [self updateModuleSelectedState];
    [self updateModeTitle];

    if (!dismissAfterSelection) {
        return;
    }

    // 短暂延迟后折叠
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self dismissViewControllerAnimated:YES completion:nil];
    });
}

/// 生成预着色的模块图标：绿色（低功耗）/ 橙色（解除温控）。
/// 关键：系统只在“选中(高亮)”状态使用 selectedGlyphColor 上色，未选中会回落到默认白色；
/// 因此这里直接把颜色绘制进图像（AlwaysOriginal），保证低功耗下图标同样是绿色，
/// 与 1×1 模块的自绘图标保持一致。
- (UIImage *)glyphImageForHighPerformance:(BOOL)highPerformance {
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
    UIImage *baseImage = [UIImage systemImageNamed:S("thermometer.sun.fill") withConfiguration:config];
    if (!baseImage) return nil;

    UIColor *color = highPerformance ? [UIColor systemOrangeColor] : [UIColor systemGreenColor];
    if ([baseImage respondsToSelector:@selector(imageWithTintColor:renderingMode:)]) {
        return [baseImage imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    if ([baseImage respondsToSelector:@selector(imageWithTintColor:)]) {
        return [baseImage imageWithTintColor:color];
    }
    return baseImage;
}

- (void)updateModuleSelectedState {
    // 高亮统一规格：只有“解除温控”启用高亮；低功耗保持普通背景（与 1×1 模块一致）。
    // 旧实现写死 setSelected:[self isTweakEnabled]（恒 YES）导致低功耗下也呈现高亮。
    NSString *currentMode = [self currentPowerMode];
    BOOL highPerformance = [currentMode isEqualToString:S(kCPUthermalFullPowerModeC)];
    if ([self respondsToSelector:@selector(setSelected:)]) {
        [self setSelected:highPerformance];
    }

    // 图标颜色同步：绿色（低功耗）/ 橙色（解除温控），与 1×1 完全一致
    UIImage *tintedGlyph = [self glyphImageForHighPerformance:highPerformance];
    if (tintedGlyph && [self respondsToSelector:@selector(setGlyphImage:)]) {
        [self setGlyphImage:tintedGlyph];
    }
    if ([self respondsToSelector:@selector(setSelectedGlyphColor:)]) {
        UIColor *glyphColor = highPerformance ? [UIColor systemOrangeColor] : [UIColor systemGreenColor];
        [self setSelectedGlyphColor:glyphColor];
    }
}

//==============================================================================
#pragma mark - Properties
//==============================================================================

- (NSArray<NSString *> *)modeValues {
    return _modeValues;
}

- (void)setModeValues:(NSArray<NSString *> *)modeValues {
    _modeValues = [modeValues copy];
    [self setupModeButtons];
}

- (NSArray<NSString *> *)modeTitles {
    return _modeTitles;
}

- (void)setModeTitles:(NSArray<NSString *> *)modeTitles {
    _modeTitles = [modeTitles copy];
    [self setupModeButtons];
}

- (NSArray<NSString *> *)modeSubtitles {
    return _modeSubtitles;
}

- (void)setModeSubtitles:(NSArray<NSString *> *)modeSubtitles {
    _modeSubtitles = [modeSubtitles copy];
    [self setupModeButtons];
}

- (NSInteger)selectedIndex {
    return _selectedIndex;
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = selectedIndex;
    [self setupModeButtons];
}

@end
