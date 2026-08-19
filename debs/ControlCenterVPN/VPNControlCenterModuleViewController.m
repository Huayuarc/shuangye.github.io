#import "VPNControlCenterModule.h"
#import <NetworkExtension/NetworkExtension.h>

@interface NEVPNManager (VPNControlCenterPrivateEnumeration)
+ (void)loadAllFromPreferencesWithCompletionHandler:(void (^)(NSArray<NEVPNManager *> *, NSError *))completionHandler;
@end

static NSString *const kVPNSelectedNodeKey = @"com.huayuarc.vpncontrolcenter.selectedNode";
static NSString *const kVPNGlyphColorKey = @"com.huayuarc.vpncontrolcenter.glyphColor";

@interface VPNControlCenterModuleViewController ()
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) UIView *activeBackground;
@property(nonatomic,strong) UIView *iconPlate;
@property(nonatomic,strong) UIImageView *glyphView;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *stateLabel;
@property(nonatomic,strong) UIView *expandedView;
@property(nonatomic,strong) UIImageView *expandedGlyph;
@property(nonatomic,strong) UILabel *expandedTitle;
@property(nonatomic,strong) UIButton *colorButton;
@property(nonatomic,strong) UILabel *expandedState;
@property(nonatomic,strong) UIScrollView *nodeScroll;
@property(nonatomic,strong) UIStackView *nodeStack;
@property(nonatomic,strong) NSArray<NEVPNManager *> *managers;
@property(nonatomic,assign) BOOL expanded;
@end

@implementation VPNControlCenterModuleViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _activeBackground = [UIView new];
    _activeBackground.userInteractionEnabled = NO;
    _activeBackground.backgroundColor = [UIColor colorWithWhite:1.0 alpha:.76];
    _activeBackground.hidden = YES;
    _activeBackground.layer.cornerRadius = 24;
    if ([_activeBackground.layer respondsToSelector:@selector(setCornerCurve:)])
        _activeBackground.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:_activeBackground];

    _button = [UIButton buttonWithType:UIButtonTypeCustom];
    [_button addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_button];

    _iconPlate = [UIView new];
    _iconPlate.userInteractionEnabled = NO;
    _iconPlate.backgroundColor = [UIColor colorWithWhite:1 alpha:.10];
    _iconPlate.layer.cornerRadius = 18;
    [_button addSubview:_iconPlate];

    _glyphView = [UIImageView new];
    _glyphView.contentMode = UIViewContentModeScaleAspectFit;
    [_iconPlate addSubview:_glyphView];

    // 紧凑模块仅显示用户提供的火箭图标，不再显示“VPN”标题。
    _titleLabel = [UILabel new];
    _titleLabel.hidden = YES;
    [_button addSubview:_titleLabel];

    // 紧凑模块只保留火箭 Logo；连接状态仍在长按节点面板显示。
    _stateLabel = [UILabel new];
    _stateLabel.hidden = YES;
    [_button addSubview:_stateLabel];

    [self buildExpandedView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vpnStatusChanged:) name:NEVPNStatusDidChangeNotification object:nil];
    [self reloadManagers];
}

- (UIImage *)rocketImage {
    NSString *path = [[NSBundle bundleForClass:self.class] pathForResource:@"VPNGlyph" ofType:@"png"];
    UIImage *image = path.length ? [UIImage imageWithContentsOfFile:path] : nil;
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (UIImage *)shieldImageWithSize:(CGFloat)size {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:@"lock.shield.fill" withConfiguration:cfg];
    if (!image) image = [UIImage systemImageNamed:@"shield.fill" withConfiguration:cfg];
    return image;
}

- (void)buildExpandedView {
    _expandedView = [UIView new];
    _expandedView.hidden = YES;
    [self.view addSubview:_expandedView];

    _expandedGlyph = [[UIImageView alloc] initWithImage:[self shieldImageWithSize:25]];
    _expandedGlyph.contentMode = UIViewContentModeScaleAspectFit;
    [_expandedView addSubview:_expandedGlyph];

    _expandedTitle = [UILabel new];
    _expandedTitle.text = @"VPN 节点";
    _expandedTitle.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    _expandedTitle.textColor = UIColor.whiteColor;
    [_expandedView addSubview:_expandedTitle];

    _colorButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _colorButton.accessibilityLabel = @"选择图标颜色";
    _colorButton.layer.cornerRadius = 13;
    _colorButton.layer.borderWidth = 2;
    _colorButton.layer.borderColor = [UIColor colorWithWhite:1 alpha:.85].CGColor;
    [_colorButton addTarget:self action:@selector(showColorPicker:) forControlEvents:UIControlEventTouchUpInside];
    [_expandedView addSubview:_colorButton];

    _expandedState = [UILabel new];
    _expandedState.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _expandedState.textColor = [UIColor colorWithWhite:1 alpha:.62];
    _expandedState.textAlignment = NSTextAlignmentRight;
    [_expandedView addSubview:_expandedState];

    _nodeScroll = [UIScrollView new];
    _nodeScroll.showsVerticalScrollIndicator = NO;
    [_expandedView addSubview:_nodeScroll];

    _nodeStack = [[UIStackView alloc] init];
    _nodeStack.axis = UILayoutConstraintAxisVertical;
    _nodeStack.spacing = 7;
    [_nodeScroll addSubview:_nodeStack];
}

- (void)reloadManagers {
    __weak typeof(self) weakSelf = self;
    [NEVPNManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NEVPNManager *> *managers, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.managers = error ? @[] : managers;
            [weakSelf refreshState];
            [weakSelf rebuildNodeButtons];
        });
    }];
}

- (NSString *)displayNameForManager:(NEVPNManager *)manager {
    return manager.localizedDescription.length ? manager.localizedDescription : @"VPN";
}

- (BOOL)isActiveStatus:(NEVPNStatus)status {
    return status == NEVPNStatusConnected || status == NEVPNStatusConnecting || status == NEVPNStatusReasserting;
}

- (NEVPNManager *)activeManager {
    // 运行时连接状态是最终真相，避免系统实际连接 Leaf、模块却勾选其他配置。
    for (NEVPNManager *manager in self.managers)
        if ([self isActiveStatus:manager.connection.status]) return manager;
    return nil;
}

- (NEVPNManager *)preferredManager {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kVPNSelectedNodeKey];
    if (saved.length) {
        for (NEVPNManager *manager in self.managers)
            if ([[self displayNameForManager:manager] isEqualToString:saved]) return manager;
    }
    for (NEVPNManager *manager in self.managers) if (manager.isEnabled) return manager;
    return self.managers.firstObject;
}

- (NEVPNManager *)selectedManager {
    return self.activeManager ?: self.preferredManager;
}

- (BOOL)isConnected { return self.activeManager != nil; }

- (void)toggle:(id)sender {
    // SpringBoard 首次加载模块时 managers 可能还未异步返回；重载完成后自动重试。
    NEVPNManager *manager = self.activeManager ?: self.preferredManager;
    if (!manager) {
        _button.enabled = NO;
        __weak typeof(self) weakSelf = self;
        [NEVPNManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NEVPNManager *> *managers, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSelf.managers = error ? @[] : managers;
                weakSelf.button.enabled = YES;
                [weakSelf refreshState];
                if (weakSelf.preferredManager) [weakSelf toggle:nil];
            });
        }];
        return;
    }
    NSError *error = nil;
    if (self.activeManager) [manager.connection stopVPNTunnel];
    else [manager.connection startVPNTunnelAndReturnError:&error];
    if (!error) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
        [self refreshState];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, .7 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self reloadManagers]; });
    } else {
        // 部分 Provider 首次启动需先刷新偏好，再用同一选择自动发起一次连接。
        __weak typeof(self) weakSelf = self;
        [manager loadFromPreferencesWithCompletionHandler:^(__unused NSError *loadError) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadManagers]; });
        }];
    }
}

- (void)vpnStatusChanged:(NSNotification *)note { dispatch_async(dispatch_get_main_queue(), ^{ [self refreshState]; }); }

- (NSArray<NSDictionary *> *)glyphColorOptions {
    return @[
        @{@"name":@"青绿", @"key":@"mint", @"color":[UIColor colorWithRed:.18 green:.91 blue:.58 alpha:1]},
        @{@"name":@"天蓝", @"key":@"blue", @"color":[UIColor colorWithRed:.18 green:.65 blue:1 alpha:1]},
        @{@"name":@"紫色", @"key":@"purple", @"color":[UIColor colorWithRed:.68 green:.42 blue:1 alpha:1]},
        @{@"name":@"粉色", @"key":@"pink", @"color":[UIColor colorWithRed:1 green:.35 blue:.66 alpha:1]},
        @{@"name":@"橙色", @"key":@"orange", @"color":[UIColor colorWithRed:1 green:.60 blue:.12 alpha:1]},
        @{@"name":@"红色", @"key":@"red", @"color":[UIColor colorWithRed:1 green:.30 blue:.32 alpha:1]}
    ];
}

- (NSString *)selectedGlyphColorKey {
    NSString *key = [[NSUserDefaults standardUserDefaults] stringForKey:kVPNGlyphColorKey];
    // 迁移旧版默认/已选白色，避免在浅色启用底板上看不到图标。
    if (!key.length || [key isEqualToString:@"white"]) {
        key = @"mint";
        [[NSUserDefaults standardUserDefaults] setObject:key forKey:kVPNGlyphColorKey];
    }
    return key;
}

- (UIColor *)selectedGlyphColor {
    NSString *key = [self selectedGlyphColorKey];
    for (NSDictionary *option in self.glyphColorOptions)
        if ([option[@"key"] isEqualToString:key]) return option[@"color"];
    return [UIColor colorWithRed:.18 green:.91 blue:.58 alpha:1];
}

- (void)showColorPicker:(id)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择显示图标颜色" message:@"所选颜色立即应用到控制中心火箭图标" preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *current = [self selectedGlyphColorKey];
    for (NSDictionary *option in self.glyphColorOptions) {
        NSString *title = [NSString stringWithFormat:@"%@%@", [option[@"key"] isEqualToString:current] ? @"✓ " : @"", option[@"name"]];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [[NSUserDefaults standardUserDefaults] setObject:option[@"key"] forKey:kVPNGlyphColorKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self refreshState];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)refreshState {
    NEVPNManager *active = self.activeManager;
    NEVPNManager *manager = active ?: self.preferredManager;
    NEVPNStatus s = manager.connection.status;
    BOOL connected = [self isConnected];
    BOOL busy = s == NEVPNStatusConnecting || s == NEVPNStatusReasserting || s == NEVPNStatusDisconnecting;
    NSString *state = !manager ? @"未配置" : (busy ? @"连接中…" : (connected ? @"已连接" : @"未连接"));
    UIColor *accent = [self selectedGlyphColor];
    UIImage *glyph = [self rocketImage];
    _glyphView.image = glyph;
    _glyphView.tintColor = accent;
    _colorButton.backgroundColor = accent;
    // 扩展面板显示期间始终隐藏紧凑启用底板，避免覆盖节点列表背景。
    _activeBackground.hidden = !connected || _expanded;
    _expandedGlyph.image = [[self shieldImageWithSize:25] imageWithTintColor:accent renderingMode:UIImageRenderingModeAlwaysOriginal];
    _iconPlate.backgroundColor = UIColor.clearColor;
    _titleLabel.textColor = UIColor.clearColor;
    _stateLabel.textColor = [UIColor colorWithWhite:1 alpha:connected ? .80 : .64];
    _stateLabel.text = state;
    NSString *name = manager ? [self displayNameForManager:manager] : @"";
    _expandedState.text = connected && name.length ? name : state;
    [self updateNodeSelectionAppearance];
}

- (UIButton *)nodeButtonForManager:(NEVPNManager *)manager index:(NSInteger)index {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.tag = index;
    button.layer.cornerRadius = 13;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [button setTitle:[self displayNameForManager:manager] forState:UIControlStateNormal];
    [button addTarget:self action:@selector(selectNode:) forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:47].active = YES;
    return button;
}

- (void)rebuildNodeButtons {
    for (UIView *view in _nodeStack.arrangedSubviews) { [_nodeStack removeArrangedSubview:view]; [view removeFromSuperview]; }
    NSInteger i = 0;
    for (NEVPNManager *manager in self.managers) [_nodeStack addArrangedSubview:[self nodeButtonForManager:manager index:i++]];
    if (!self.managers.count) {
        UILabel *empty = [UILabel new]; empty.text = @"未找到系统 VPN 配置"; empty.textAlignment = NSTextAlignmentCenter;
        empty.textColor = [UIColor colorWithWhite:1 alpha:.6]; empty.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        [empty.heightAnchor constraintEqualToConstant:60].active = YES; [_nodeStack addArrangedSubview:empty];
    }
    [self updateNodeSelectionAppearance];
    [self.view setNeedsLayout];
}

- (void)updateNodeSelectionAppearance {
    NEVPNManager *selected = self.selectedManager;
    for (UIView *view in _nodeStack.arrangedSubviews) {
        if (![view isKindOfClass:UIButton.class]) continue;
        UIButton *button = (UIButton *)view;
        BOOL on = button.tag < self.managers.count && self.managers[button.tag] == selected;
        button.backgroundColor = on ? [UIColor colorWithRed:.12 green:.52 blue:1 alpha:.82] : [UIColor colorWithWhite:1 alpha:.10];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightBold];
        UIImage *icon = [UIImage systemImageNamed:on ? @"checkmark.circle.fill" : @"circle" withConfiguration:cfg];
        [button setImage:[icon imageWithTintColor:[UIColor colorWithWhite:1 alpha:on ? 1 : .42] renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
        button.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    }
}

- (void)selectNode:(UIButton *)sender {
    if (sender.tag >= self.managers.count) return;
    NEVPNManager *manager = self.managers[sender.tag];
    NEVPNManager *active = self.activeManager;
    if (active && active != manager) [active.connection stopVPNTunnel];
    [[NSUserDefaults standardUserDefaults] setObject:[self displayNameForManager:manager] forKey:kVPNSelectedNodeKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new]; [feedback selectionChanged];
    [self refreshState];
    // 节点选中后保持面板内状态正确；系统收起时尺寸保护会恢复紧凑布局。
    [self.view setNeedsLayout];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, .35 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self reloadManagers]; });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 每次重新拉出控制中心都从紧凑态开始，清理上次扩展残留。
    _expanded = NO;
    _button.hidden = NO;
    _expandedView.hidden = YES;
    [self reloadManagers];
    [self.view setNeedsLayout];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; CGFloat w = CGRectGetWidth(b), h = CGRectGetHeight(b);
    _activeBackground.frame = b;
    _activeBackground.layer.cornerRadius = MIN(24.0, MIN(w,h) * .23);
    _button.frame = b; _expandedView.frame = b;

    // ControlCenter 在部分系统版本收起模块时不回调 willReturn...；
    // 始终结合实时尺寸判断，防止展开标题残留并溢出紧凑方框。
    BOOL roomyBounds = w >= 220.0 && h >= 180.0;
    BOOL showExpanded = _expanded && roomyBounds;
    _button.hidden = showExpanded;
    _activeBackground.hidden = showExpanded || ![self isConnected];
    _expandedView.hidden = !showExpanded;

    if (!showExpanded) {
        // 按模块实时尺寸自适应；裁边后的素材占约 43%，保留原生模块留白。
        CGFloat glyph = MIN(48.0, MAX(40.0, MIN(w, h) * .43));
        _iconPlate.frame = CGRectIntegral(CGRectMake((w-glyph)/2.0, (h-glyph)/2.0, glyph, glyph));
        _iconPlate.layer.cornerRadius = 0;
        _glyphView.frame = _iconPlate.bounds;
        _titleLabel.frame = CGRectZero;
        _stateLabel.frame = CGRectZero;
    } else {
        CGFloat pad = 16;
        _expandedGlyph.frame = CGRectMake(pad, 14, 30, 30);
        _expandedTitle.frame = CGRectMake(54, 12, MIN(105, MAX(0,w-215)), 24);
        _colorButton.frame = CGRectMake(CGRectGetMaxX(_expandedTitle.frame)+8, 13, 26, 26);
        _expandedState.frame = CGRectMake(w-104, 14, 88, 22);
        _nodeScroll.frame = CGRectMake(pad, 52, w-pad*2, MAX(0, h-64));
        _nodeStack.frame = CGRectMake(0, 0, CGRectGetWidth(_nodeScroll.bounds), MAX(CGRectGetHeight(_nodeScroll.bounds), self.nodeStack.arrangedSubviews.count*54));
        _nodeScroll.contentSize = CGSizeMake(CGRectGetWidth(_nodeScroll.bounds), CGRectGetHeight(_nodeStack.frame));
    }
}

- (BOOL)shouldBeginTransitionToExpandedContentModule { return YES; }
- (void)willTransitionToExpandedContentMode:(BOOL)animated {
    _expanded = YES; _button.hidden = YES; _expandedView.hidden = NO;
    [self reloadManagers]; [self.view setNeedsLayout];
}
- (void)willReturnToExpandedContentModule {
    _expanded = NO; _button.hidden = NO; _expandedView.hidden = YES;
    [self refreshState]; [self.view setNeedsLayout];
}
- (CGFloat)preferredExpandedContentHeight { return 330; }
- (CGFloat)preferredExpandedContentWidth { return MIN(MAX(CGRectGetWidth(UIScreen.mainScreen.bounds)-40, 300), 370); }
- (BOOL)providesOwnPlatter { return NO; }

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
