#import "CPUthermalCCModuleViewController.h"
#import <spawn.h>
#import <sys/wait.h>
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
- (void)togglePowerMode;
- (void)selectPowerModeAtIndex:(NSInteger)index;
- (void)selectPowerModeAtIndex:(NSInteger)index dismissAfterSelection:(BOOL)dismissAfterSelection;
- (void)centerMenuItemLabelsInView:(UIView *)view;
- (void)centerMenuItemLabelsAfterLayout;
- (BOOL)isModeTitle:(NSString *)text;
- (NSString *)menuTitleForTitle:(NSString *)title selected:(BOOL)isSelected;
@end

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
@synthesize selectedIndex = _selectedIndex;

//==============================================================================
#pragma mark - Prefs Helpers
//==============================================================================

/// 解析 /var/jb 真实路径，拼接 Prefs 路径
- (NSString *)prefPath {
    return CPUthermalCurrentPrefPath();
}

/// 读取当前功率模式值
- (NSString *)currentPowerMode {
    NSDictionary *prefs = CPUthermalReadPrefs();
    NSString *mode = prefs[S("powerMode")];
    if ([mode isKindOfClass:[NSString class]] && [mode length] > 0) {
        return mode;
    }
    return S("fullPower"); // 默认解除温控
}

/// 写入功率模式并发送通知
- (void)savePowerMode:(NSString *)mode {
    NSMutableDictionary *prefs = CPUthermalReadMutablePrefs();
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    prefs[S("powerMode")] = mode ?: S("fullPower");

    CPUthermalWritePrefs(prefs);
    notify_post(kCPUthermalSettingsChangedNotifC);
    notify_post(kCPUthermalPowerModeChangedNotifC);
    [self restartThermalmonitord];
}

/// 重启 thermalmonitord 进程
- (void)restartThermalmonitord {
    CPUthermalRestartThermalmonitordSoon();
}

//==============================================================================
#pragma mark - Initialization
//==============================================================================

- (instancetype)init {
    self = [super init];
    if (self) {
        _modeValues = @[S("lowPower"), S("fullPower")];
        _modeTitles = @[S("低功耗"), S("解除温控")];

        // 读取当前设置的模式
        NSString *currentMode = [self currentPowerMode];
        _selectedIndex = [_modeValues indexOfObject:currentMode];
        if (_selectedIndex == NSNotFound) {
            _selectedIndex = 1; // 默认选中"解除温控"
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
        [self setUseTrailingCheckmarkLayout:NO];
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
    [self centerMenuItemLabelsAfterLayout];
}

//==============================================================================
#pragma mark - Public
//==============================================================================

- (void)refreshState {
    [self updateSelectedIndexFromCurrentMode];
    [self setupModeButtons];
    if ([self respondsToSelector:@selector(setSelected:)]) {
        [self setSelected:(self.selectedIndex == 0) ? NO : YES];
    }
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
    return 214.0;
}

- (CGFloat)preferredExpandedContentWidth {
    return 280.0;
}

- (BOOL)providesOwnPlatter {
    return NO;
}

- (BOOL)_toggleModuleExpanded {
    return YES;
}

//==============================================================================
#pragma mark - Setup
//==============================================================================

- (void)setupView {
    [self updateSelectedIndexFromCurrentMode];

    // 设置菜单项
    [self setupModeButtons];

    // 应用当前选中状态
    if ([self respondsToSelector:@selector(setSelected:)]) {
        [self setSelected:(self.selectedIndex == 0) ? NO : YES];
    }
}

- (void)setupModeButtons {
    NSString *currentMode = [self currentPowerMode];
    BOOL isFullPower = [currentMode isEqualToString:S("fullPower")];
    NSUInteger itemCount = MIN(self.modeValues.count, self.modeTitles.count);

    NSMutableArray *items = [NSMutableArray arrayWithCapacity:itemCount];
    for (NSUInteger i = 0; i < itemCount; i++) {
        NSString *title = self.modeTitles[i];
        BOOL isSelected = ((NSInteger)i == self.selectedIndex);
        NSString *displayTitle = [self menuTitleForTitle:title selected:isSelected];

        NSString *identifier = S("cpu-item-");
        identifier = [identifier stringByAppendingFormat:S("%lu"), (unsigned long)i];
        __weak typeof(self) weakSelf = self;
        NSInteger itemIndex = (NSInteger)i;
        CCUIMenuModuleItem *item = [[CCUIMenuModuleItem alloc] initWithTitle:displayTitle identifier:identifier handler:^{
            [weakSelf selectPowerModeAtIndex:itemIndex];
        }];
        if (!item) {
            continue;
        }
        if ([item respondsToSelector:@selector(setSelected:)]) {
            [item setSelected:NO];
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

    [self centerMenuItemLabelsAfterLayout];
}

- (NSString *)menuTitleForTitle:(NSString *)title selected:(BOOL)isSelected {
    if (!isSelected) {
        return title;
    }
    return [title stringByAppendingString:S("  ✓")];
}

- (void)centerMenuItemLabelsAfterLayout {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.view layoutIfNeeded];
        [self centerMenuItemLabelsInView:self.view];
    });
}

- (BOOL)isModeTitle:(NSString *)text {
    if (![text isKindOfClass:[NSString class]] || [text length] == 0) {
        return NO;
    }
    for (NSString *title in self.modeTitles) {
        if ([text isEqualToString:title] || [text isEqualToString:[self menuTitleForTitle:title selected:YES]]) {
            return YES;
        }
    }
    return NO;
}

- (void)centerMenuItemLabelsInView:(UIView *)view {
    if (!view) {
        return;
    }

    NSString *className = NSStringFromClass([view class]);
    BOOL isMenuItemView = [className containsString:S("MenuModuleItem")];
    if (isMenuItemView) {
        if ([view respondsToSelector:@selector(setUseTrailingCheckmarkLayout:)]) {
            [view setUseTrailingCheckmarkLayout:NO];
        }
        if ([view respondsToSelector:@selector(setUseTrailingInset:)]) {
            [view setUseTrailingInset:NO];
        }
        if ([view respondsToSelector:@selector(setIndentation:)]) {
            [view setIndentation:0.0];
        }
        if ([view respondsToSelector:@selector(setPreservesSuperviewLayoutMargins:)]) {
            [view setPreservesSuperviewLayoutMargins:NO];
        }
        view.layoutMargins = UIEdgeInsetsZero;

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
            if (![self isModeTitle:label.text]) {
                continue;
            }
            label.textAlignment = NSTextAlignmentCenter;
            label.numberOfLines = 1;
            label.translatesAutoresizingMaskIntoConstraints = YES;
            label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;

            UIView *labelContainer = label.superview ?: view;
            CGFloat targetWidth = CGRectGetWidth(view.bounds);
            CGRect frameInView = [view convertRect:view.bounds toView:labelContainer];
            CGRect frame = label.frame;
            frame.origin.x = frameInView.origin.x;
            frame.size.width = targetWidth;
            label.frame = frame;
        }
    }

    for (UIView *subview in view.subviews) {
        [self centerMenuItemLabelsInView:subview];
    }
}

//==============================================================================
#pragma mark - Button Actions
//==============================================================================

- (void)updateSelectedIndexFromCurrentMode {
    NSString *currentMode = [self currentPowerMode];
    NSInteger newIndex = [self.modeValues indexOfObject:currentMode];
    if (newIndex == NSNotFound) {
        newIndex = 1;
    }
    _selectedIndex = newIndex;
}

- (void)buttonTapped:(id)arg forEvent:(id)event {
    [self togglePowerMode];
}

- (void)togglePowerMode {
    [self updateSelectedIndexFromCurrentMode];

    NSInteger nextIndex = (self.selectedIndex == 0) ? 1 : 0;
    [self selectPowerModeAtIndex:nextIndex dismissAfterSelection:NO];
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
    if ([self respondsToSelector:@selector(setSelected:)]) {
        [self setSelected:(self.selectedIndex == 0) ? NO : YES];
    }

    if (!dismissAfterSelection) {
        return;
    }

    // 短暂延迟后折叠
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self dismissViewControllerAnimated:YES completion:nil];
    });
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

- (NSInteger)selectedIndex {
    return _selectedIndex;
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = selectedIndex;
    [self setupModeButtons];
}

@end
