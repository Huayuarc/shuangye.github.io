#import "VPNControlCenterModule.h"
#import <NetworkExtension/NetworkExtension.h>

@interface NEVPNManager (VPNControlCenterPrivateEnumeration)
+ (void)loadAllFromPreferencesWithCompletionHandler:(void (^)(NSArray<NEVPNManager *> *, NSError *))completionHandler;
@end

static NSString *const kVPNSelectedNodeKey = @"com.huayuarc.vpncontrolcenter.selectedNode";

@interface VPNControlCenterModuleViewController ()
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) UIView *iconPlate;
@property(nonatomic,strong) UIImageView *glyphView;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *stateLabel;
@property(nonatomic,strong) UIView *expandedView;
@property(nonatomic,strong) UIImageView *expandedGlyph;
@property(nonatomic,strong) UILabel *expandedTitle;
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

    _titleLabel = [UILabel new];
    _titleLabel.text = @"VPN";
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [_button addSubview:_titleLabel];

    _stateLabel = [UILabel new];
    _stateLabel.textAlignment = NSTextAlignmentCenter;
    _stateLabel.adjustsFontSizeToFitWidth = YES;
    _stateLabel.minimumScaleFactor = .75;
    [_button addSubview:_stateLabel];

    [self buildExpandedView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vpnStatusChanged:) name:NEVPNStatusDidChangeNotification object:nil];
    [self reloadManagers];
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
    NEVPNManager *manager = self.activeManager ?: self.preferredManager;
    if (!manager) return;
    NSError *error = nil;
    if (self.activeManager) [manager.connection stopVPNTunnel];
    else [manager.connection startVPNTunnelAndReturnError:&error];
    if (!error) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
        [self refreshState];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, .7 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self reloadManagers]; });
    }
}

- (void)vpnStatusChanged:(NSNotification *)note { dispatch_async(dispatch_get_main_queue(), ^{ [self refreshState]; }); }

- (void)refreshState {
    NEVPNManager *active = self.activeManager;
    NEVPNManager *manager = active ?: self.preferredManager;
    NEVPNStatus s = manager.connection.status;
    BOOL connected = [self isConnected];
    BOOL busy = s == NEVPNStatusConnecting || s == NEVPNStatusReasserting || s == NEVPNStatusDisconnecting;
    NSString *state = !manager ? @"未配置" : (busy ? @"连接中…" : (connected ? @"已连接" : @"未连接"));
    UIColor *accent = connected ? [UIColor colorWithRed:.20 green:.90 blue:.55 alpha:1] : UIColor.whiteColor;
    UIImage *glyph = [[self shieldImageWithSize:29] imageWithTintColor:accent renderingMode:UIImageRenderingModeAlwaysOriginal];
    _glyphView.image = glyph;
    _expandedGlyph.image = [[self shieldImageWithSize:25] imageWithTintColor:accent renderingMode:UIImageRenderingModeAlwaysOriginal];
    _iconPlate.backgroundColor = connected ? [UIColor colorWithRed:.10 green:.80 blue:.45 alpha:.20] : [UIColor colorWithWhite:1 alpha:.10];
    _titleLabel.textColor = UIColor.whiteColor;
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
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 12);
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
        button.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, -8);
        button.titleEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 0);
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
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadManagers]; }

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; CGFloat w = CGRectGetWidth(b), h = CGRectGetHeight(b);
    _button.frame = b; _expandedView.frame = b;
    if (!_expanded) {
        CGFloat plate = MIN(44, MAX(38, w * .35));
        CGFloat total = plate + 4 + 18 + 15;
        CGFloat y = floor(MAX(6, (h-total)/2));
        _iconPlate.frame = CGRectMake(floor((w-plate)/2), y, plate, plate); _iconPlate.layer.cornerRadius = plate/2;
        _glyphView.frame = CGRectInset(_iconPlate.bounds, 8, 8); y += plate + 4;
        _titleLabel.frame = CGRectMake(4, y, w-8, 18); y += 17;
        _stateLabel.frame = CGRectMake(4, y, w-8, 15);
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        _stateLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    } else {
        CGFloat pad = 16;
        _expandedGlyph.frame = CGRectMake(pad, 14, 30, 30);
        _expandedTitle.frame = CGRectMake(54, 12, w-150, 24);
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
