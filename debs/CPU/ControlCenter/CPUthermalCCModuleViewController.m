#import "CPUthermalCCModuleViewController.h"
#import <notify.h>
#import <Foundation/Foundation.h>
#import <CPUthermalPaths.h>

// ============================================================
// 注意: 禁止使用 @"" ObjC 字符串常量
// roothide 重映射会破坏 __cfstring 内部指针，导致 SIGBUS
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================

@interface CPUthermalCCModuleViewController ()
- (void)updateSelectedIndexFromCurrentMode;
- (BOOL)isTweakEnabled;
- (void)saveTweakEnabled:(BOOL)enabled;
- (void)toggleTweakEnabled;
- (void)updateModuleSelectedState;
- (void)selectPowerModeAtIndex:(NSInteger)index;
- (void)selectPowerModeAtIndex:(NSInteger)index dismissAfterSelection:(BOOL)dismissAfterSelection;
- (CGFloat)availableExpandedContentWidth;
- (void)applyCompactMenuInsetsToLabel:(UILabel *)label inMenuItemView:(UIView *)menuItemView;
- (void)styleMenuItemLabelsInView:(UIView *)view;
- (void)styleMenuItemLabelsAfterLayout;
- (BOOL)isModeTitle:(NSString *)text;
- (BOOL)isModeSubtitle:(NSString *)text;
@end

static const CGFloat kCPUthermalCCPreferredExpandedWidth = 320.0;
static const CGFloat kCPUthermalCCPreferredExpandedHeight = 250.0;
static const CGFloat kCPUthermalCCMinimumScreenMargin = 30.0;
static const CGFloat kCPUthermalCCMenuLeadingInset = 18.0;
static const CGFloat kCPUthermalCCMenuTrailingInset = 46.0;
static const CGFloat kCPUthermalCCTitleFontSize = 15.0;
static const CGFloat kCPUthermalCCSubtitleFontSize = 11.0;

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
    NSDictionary *prefs = CPUthermalReadPrefs();
    NSString *mode = prefs[S("powerMode")];
    if ([mode isKindOfClass:[NSString class]] && [mode length] > 0) {
        return mode;
    }
    return S(kCPUthermalDefaultPowerModeC); // 默认解除温控
}

- (BOOL)isTweakEnabled {
    NSDictionary *prefs = CPUthermalReadPrefs();
    id value = prefs[S("enabled")];
    return value ? [value boolValue] : YES;
}

- (void)saveTweakEnabled:(BOOL)enabled {
    NSMutableDictionary *prefs = CPUthermalReadMutablePrefs();
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    prefs[S("enabled")] = [NSNumber numberWithBool:enabled];

    CPUthermalWritePrefs(prefs);
    notify_post(kCPUthermalSettingsChangedNotifC);
    if (enabled) {
        CPUthermalRestartThermalmonitordSoon();
    }
}

/// 写入功率模式并发送通知
- (void)savePowerMode:(NSString *)mode {
    NSMutableDictionary *prefs = CPUthermalReadMutablePrefs();
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    prefs[S("powerMode")] = mode ?: S(kCPUthermalDefaultPowerModeC);
    prefs[S("enabled")] = [NSNumber numberWithBool:YES];
    prefs[S("cpuProtection")] = [NSNumber numberWithBool:YES];

    CPUthermalWritePrefs(prefs);
    notify_post(kCPUthermalSettingsChangedNotifC);
    notify_post(kCPUthermalPowerModeChangedNotifC);
    CPUthermalRestartThermalmonitordSoon();
}


//==============================================================================
#pragma mark - Initialization
//==============================================================================

- (instancetype)init {
    self = [super init];
    if (self) {
        _modeValues = @[S(kCPUthermalLowPowerModeC), S(kCPUthermalFullPowerModeC)];
        _modeTitles = @[S("低功耗"), S("解除温控")];
        _modeSubtitles = @[S("2016/1380MHz"), S("默认满性能")];

        // 读取当前设置的模式
        NSString *currentMode = [self currentPowerMode];
        _selectedIndex = [_modeValues indexOfObject:currentMode];
        if (_selectedIndex == NSNotFound) {
            _selectedIndex = [_modeValues indexOfObject:S(kCPUthermalDefaultPowerModeC)];
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
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
    UIImage *glyphImage = [UIImage systemImageNamed:S("thermometer.sun.fill") withConfiguration:config];
    if ([self respondsToSelector:@selector(setGlyphImage:)]) {
        [self setGlyphImage:glyphImage];
    }
    if ([self respondsToSelector:@selector(setSelectedGlyphColor:)]) {
        [self setSelectedGlyphColor:[UIColor systemOrangeColor]];
    }

    if ([self respondsToSelector:@selector(setUseTrailingCheckmarkLayout:)]) {
        [self setUseTrailingCheckmarkLayout:YES];
    }
    if ([self respondsToSelector:@selector(setUseTallLayout:)]) {
        [self setUseTallLayout:NO];
    }
    if ([self respondsToSelector:@selector(setHideGlyphInHeader:)]) {
        [self setHideGlyphInHeader:NO];
    }
    if ([self respondsToSelector:@selector(setShouldProvideOwnPlatter:)]) {
        [self setShouldProvideOwnPlatter:NO];
    }

    // 布局 UI
    [self setupView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshState];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self styleMenuItemLabelsAfterLayout];
}

//==============================================================================
#pragma mark - Public
//==============================================================================

- (void)refreshState {
    [self updateSelectedIndexFromCurrentMode];
    [self setupModeButtons];
    [self updateModuleSelectedState];
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
    return kCPUthermalCCPreferredExpandedHeight;
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

    [self styleMenuItemLabelsAfterLayout];
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

- (void)styleMenuItemLabelsAfterLayout {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.view layoutIfNeeded];
        [self styleMenuItemLabelsInView:self.view];
    });
}

- (BOOL)isModeTitle:(NSString *)text {
    if (![text isKindOfClass:[NSString class]] || [text length] == 0) {
        return NO;
    }
    for (NSString *title in self.modeTitles) {
        if ([text isEqualToString:title]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)isModeSubtitle:(NSString *)text {
    if (![text isKindOfClass:[NSString class]] || [text length] == 0) {
        return NO;
    }
    for (NSString *subtitle in self.modeSubtitles) {
        if ([text isEqualToString:subtitle]) {
            return YES;
        }
    }
    return NO;
}

- (void)applyCompactMenuInsetsToLabel:(UILabel *)label inMenuItemView:(UIView *)menuItemView {
    if (!label || !menuItemView || !label.superview || CGRectGetWidth(menuItemView.bounds) <= 0) {
        return;
    }

    UIView *labelContainer = label.superview;
    CGRect labelFrame = label.frame;
    CGPoint labelOriginInItem = [labelContainer convertPoint:labelFrame.origin toView:menuItemView];
    CGFloat maxLabelWidth = CGRectGetWidth(menuItemView.bounds) - kCPUthermalCCMenuLeadingInset - kCPUthermalCCMenuTrailingInset;
    if (maxLabelWidth <= 0) {
        return;
    }

    CGFloat adjustedMinX = MAX(labelOriginInItem.x, kCPUthermalCCMenuLeadingInset);
    CGFloat adjustedWidth = MIN(CGRectGetWidth(labelFrame), maxLabelWidth);
    if (adjustedMinX + adjustedWidth > CGRectGetWidth(menuItemView.bounds) - kCPUthermalCCMenuTrailingInset) {
        adjustedWidth = CGRectGetWidth(menuItemView.bounds) - kCPUthermalCCMenuTrailingInset - adjustedMinX;
    }
    if (adjustedWidth <= 0) {
        return;
    }

    CGPoint adjustedOrigin = [menuItemView convertPoint:CGPointMake(adjustedMinX, labelOriginInItem.y) toView:labelContainer];
    labelFrame.origin.x = adjustedOrigin.x;
    labelFrame.size.width = adjustedWidth;
    label.frame = labelFrame;
}

- (void)styleMenuItemLabelsInView:(UIView *)view {
    if (!view) {
        return;
    }

    NSString *className = NSStringFromClass([view class]);
    BOOL isMenuItemView = [className containsString:S("MenuModuleItem")];
    if (isMenuItemView) {
        if ([view respondsToSelector:@selector(setUseTrailingCheckmarkLayout:)]) {
            [view setUseTrailingCheckmarkLayout:YES];
        }
        if ([view respondsToSelector:@selector(setUseTrailingInset:)]) {
            [view setUseTrailingInset:YES];
        }
        if ([view respondsToSelector:@selector(setIndentation:)]) {
            [view setIndentation:kCPUthermalCCMenuLeadingInset];
        }

        UILabel *titleLabel = nil;
        UILabel *subtitleLabel = nil;
        if ([view respondsToSelector:@selector(titleLabel)]) {
            titleLabel = [view titleLabel];
        }
        if ([view respondsToSelector:@selector(subtitleLabel)]) {
            subtitleLabel = [view subtitleLabel];
        }

        NSMutableArray<UILabel *> *labels = [NSMutableArray array];
        if (titleLabel) {
            [labels addObject:titleLabel];
        }
        if (subtitleLabel && subtitleLabel != titleLabel) {
            [labels addObject:subtitleLabel];
        }
        for (UIView *subview in view.subviews) {
            if ([subview isKindOfClass:[UILabel class]] && ![labels containsObject:(UILabel *)subview]) {
                [labels addObject:(UILabel *)subview];
            }
            for (UIView *nestedSubview in subview.subviews) {
                if ([nestedSubview isKindOfClass:[UILabel class]] && ![labels containsObject:(UILabel *)nestedSubview]) {
                    [labels addObject:(UILabel *)nestedSubview];
                }
            }
        }

        for (UILabel *label in labels) {
            if (![label isKindOfClass:[UILabel class]]) {
                continue;
            }
            BOOL isTitle = [self isModeTitle:label.text];
            BOOL isSubtitle = [self isModeSubtitle:label.text];
            if (!isTitle && !isSubtitle) {
                continue;
            }
            label.textAlignment = NSTextAlignmentLeft;
            label.numberOfLines = 1;
            label.lineBreakMode = NSLineBreakByTruncatingTail;
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.82;
            if (isTitle) {
                label.font = [UIFont systemFontOfSize:kCPUthermalCCTitleFontSize weight:UIFontWeightSemibold];
                label.textColor = [UIColor colorWithWhite:1.0 alpha:0.95];
            } else {
                label.font = [UIFont systemFontOfSize:kCPUthermalCCSubtitleFontSize weight:UIFontWeightRegular];
                label.textColor = [UIColor colorWithWhite:1.0 alpha:0.42];
            }
            [self applyCompactMenuInsetsToLabel:label inMenuItemView:view];
        }
    }

    for (UIView *subview in view.subviews) {
        [self styleMenuItemLabelsInView:subview];
    }
}

//==============================================================================
#pragma mark - Button Actions
//==============================================================================

- (void)updateSelectedIndexFromCurrentMode {
    NSString *currentMode = [self currentPowerMode];
    NSInteger newIndex = [self.modeValues indexOfObject:currentMode];
    if (newIndex == NSNotFound) {
        newIndex = [self.modeValues indexOfObject:S(kCPUthermalDefaultPowerModeC)];
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
    [self updateSelectedIndexFromCurrentMode];

    BOOL nextEnabled = ![self isTweakEnabled];
    [self saveTweakEnabled:nextEnabled];
    [self setupModeButtons];
    [self updateModuleSelectedState];
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

    if (!dismissAfterSelection) {
        return;
    }

    // 短暂延迟后折叠
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self dismissViewControllerAnimated:YES completion:nil];
    });
}

- (void)updateModuleSelectedState {
    if ([self respondsToSelector:@selector(setSelected:)]) {
        [self setSelected:[self isTweakEnabled]];
    }

    if ([self respondsToSelector:@selector(setSelectedGlyphColor:)]) {
        NSString *currentMode = [self currentPowerMode];
        UIColor *glyphColor = [currentMode isEqualToString:S(kCPUthermalLowPowerModeC)] ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
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
