#import "VPNNodeModule.h"
#import <NetworkExtension/NetworkExtension.h>

@interface NEVPNManager (VPNNodeEnumeration)
+ (void)loadAllFromPreferencesWithCompletionHandler:(void (^)(NSArray<NEVPNManager *> *, NSError *))handler;
@end

static NSString *const VPNPreferredNameKey = @"com.huayuarc.vpnnodeselector.preferredName";
static const NSTimeInterval VPNSwitchTimeout = 5.0;

@interface VPNNodeViewController ()
@property(nonatomic,strong) UIView *panel;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIScrollView *scrollView;
@property(nonatomic,strong) UIStackView *stackView;
@property(nonatomic,strong) NSArray<NEVPNManager *> *managers;
@property(nonatomic,strong) NEVPNManager *pendingManager;
@property(nonatomic,assign) BOOL expanded;
@property(nonatomic,assign) NSUInteger loadGeneration;
@property(nonatomic,assign) NSUInteger switchGeneration;
@end

@implementation VPNNodeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    _panel = [UIView new];
    _panel.hidden = YES;
    [self.view addSubview:_panel];
    _titleLabel = [UILabel new];
    _titleLabel.text = @"选择 VPN 节点";
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [_panel addSubview:_titleLabel];
    _statusLabel = [UILabel new];
    _statusLabel.textAlignment = NSTextAlignmentRight;
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [_panel addSubview:_statusLabel];
    _scrollView = [UIScrollView new];
    _scrollView.showsVerticalScrollIndicator = YES;
    [_panel addSubview:_scrollView];
    _stackView = [UIStackView new];
    _stackView.axis = UILayoutConstraintAxisVertical;
    _stackView.spacing = 8;
    [_scrollView addSubview:_stackView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vpnStatusChanged:) name:NEVPNStatusDidChangeNotification object:nil];
    [self reloadManagers];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (CGRectGetWidth(self.view.bounds) < 220 || CGRectGetHeight(self.view.bounds) < 180) self.expanded = NO;
    [self reloadManagers];
}

- (NSString *)nameForManager:(NEVPNManager *)manager {
    NSString *name = manager.localizedDescription;
    return name.length ? name : @"未命名 VPN";
}
- (BOOL)isActiveStatus:(NEVPNStatus)status {
    return status == NEVPNStatusConnected || status == NEVPNStatusConnecting || status == NEVPNStatusReasserting;
}
- (NEVPNManager *)activeManager {
    for (NEVPNManager *manager in self.managers) if ([self isActiveStatus:manager.connection.status]) return manager;
    return nil;
}
- (NEVPNManager *)preferredManager {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:VPNPreferredNameKey];
    if (saved.length) for (NEVPNManager *manager in self.managers) if ([[self nameForManager:manager] isEqualToString:saved]) return manager;
    for (NEVPNManager *manager in self.managers) if (manager.enabled) return manager;
    return self.managers.firstObject;
}
- (NEVPNManager *)displayedManager { return [self activeManager] ?: self.pendingManager ?: [self preferredManager]; }

- (void)reloadManagers {
    NSUInteger generation = ++self.loadGeneration;
    __weak typeof(self) weakSelf = self;
    Class cls = NSClassFromString(@"NEVPNManager");
    SEL allSelector = NSSelectorFromString(@"loadAllFromPreferencesWithCompletionHandler:");
    if (cls && [cls respondsToSelector:allSelector]) {
        [NEVPNManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NEVPNManager *> *items, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) selfRef = weakSelf;
                if (!selfRef || generation != selfRef.loadGeneration) return;
                selfRef.managers = error ? @[] : (items ?: @[]);
                [selfRef updateEverything];
            });
        }];
        return;
    }
    NEVPNManager *manager = NEVPNManager.sharedManager;
    [manager loadFromPreferencesWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) selfRef = weakSelf;
            if (!selfRef || generation != selfRef.loadGeneration) return;
            selfRef.managers = error ? @[] : @[manager];
            [selfRef updateEverything];
        });
    }];
}

- (void)updateEverything {
    NEVPNManager *active = [self activeManager];
    ((VPNNodeModule *)self.module).selected = active != nil;
    self.statusLabel.text = active ? [self nameForManager:active] : (self.managers.count ? @"未连接" : @"无配置");
    [self rebuildRows];
}

- (void)rebuildRows {
    for (UIView *view in self.stackView.arrangedSubviews.copy) {
        [self.stackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NEVPNManager *chosen = [self displayedManager];
    [self.managers enumerateObjectsUsingBlock:^(NEVPNManager *manager, NSUInteger index, BOOL *stop) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = (NSInteger)index;
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        button.layer.cornerRadius = 12;
        button.clipsToBounds = YES;
        button.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
        [button setTitle:[NSString stringWithFormat:@"  %@", [self nameForManager:manager]] forState:UIControlStateNormal];
        BOOL selected = manager == chosen;
        UIImage *mark = [UIImage systemImageNamed:selected ? @"checkmark.circle.fill" : @"circle"];
        [button setImage:mark forState:UIControlStateNormal];
        button.tintColor = selected ? UIColor.systemBlueColor : UIColor.tertiaryLabelColor;
        button.backgroundColor = selected ? [UIColor.systemBlueColor colorWithAlphaComponent:0.16] : [UIColor.secondarySystemFillColor colorWithAlphaComponent:0.72];
        [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
        [button addTarget:self action:@selector(nodeTapped:) forControlEvents:UIControlEventTouchUpInside];
        [button.heightAnchor constraintEqualToConstant:48].active = YES;
        [self.stackView addArrangedSubview:button];
    }];
}

- (void)nodeTapped:(UIButton *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= self.managers.count) return;
    NEVPNManager *target = self.managers[(NSUInteger)sender.tag];
    [[NSUserDefaults standardUserDefaults] setObject:[self nameForManager:target] forKey:VPNPreferredNameKey];
    NEVPNManager *active = [self activeManager];
    if (!active || active == target) {
        self.pendingManager = nil;
        [self rebuildRows];
        return;
    }
    self.pendingManager = target;
    NSUInteger token = ++self.switchGeneration;
    [active.connection stopVPNTunnel];
    [self rebuildRows];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VPNSwitchTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) selfRef = weakSelf;
        if (!selfRef || token != selfRef.switchGeneration || selfRef.pendingManager != target) return;
        [selfRef startPendingManager];
    });
}

- (void)startPendingManager {
    NEVPNManager *target = self.pendingManager;
    if (!target) return;
    self.pendingManager = nil;
    ++self.switchGeneration;
    NSError *error = nil;
    [target.connection startVPNTunnelAndReturnError:&error];
    [self reloadManagers];
}

- (void)toggleVPN {
    NEVPNManager *active = [self activeManager];
    if (active) {
        self.pendingManager = nil;
        ++self.switchGeneration;
        [active.connection stopVPNTunnel];
        return;
    }
    NEVPNManager *target = [self preferredManager];
    if (!target) { [self reloadManagers]; return; }
    NSError *error = nil;
    [target.connection startVPNTunnelAndReturnError:&error];
    [self reloadManagers];
}

- (void)buttonTapped:(id)sender forEvent:(id)event {
    if (!self.expanded) [self toggleVPN];
}

- (void)vpnStatusChanged:(NSNotification *)notification {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) selfRef = weakSelf;
        if (!selfRef) return;
        if (selfRef.pendingManager && ![selfRef activeManager]) [selfRef startPendingManager];
        else [selfRef reloadManagers];
    });
}

- (BOOL)shouldBeginTransitionToExpandedContentModule { return YES; }
- (BOOL)shouldFinishTransitionToExpandedContentModule { return YES; }
- (void)willTransitionToExpandedContentMode:(BOOL)animated {
    self.expanded = YES;
    self.panel.hidden = NO;
    [self reloadManagers];
    [self.view setNeedsLayout];
}
- (void)willReturnToExpandedContentModule {
    self.expanded = NO;
    self.panel.hidden = YES;
    [self.view setNeedsLayout];
}
- (CGFloat)preferredExpandedContentHeight { return 360.0; }
- (CGFloat)preferredExpandedContentWidth {
    CGFloat width = MIN(CGRectGetWidth(UIScreen.mainScreen.bounds) - 32.0, 390.0);
    return MAX(width, 300.0);
}
- (BOOL)providesOwnPlatter { return NO; }

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGFloat width = CGRectGetWidth(bounds), height = CGRectGetHeight(bounds);
    BOOL physicallyExpanded = width >= 220.0 && height >= 180.0;
    if (!physicallyExpanded) self.expanded = NO;
    self.panel.hidden = !(self.expanded && physicallyExpanded);
    if (self.panel.hidden) return;
    self.panel.frame = bounds;
    CGFloat padding = 16.0;
    self.titleLabel.frame = CGRectMake(padding, 14.0, width - 150.0, 27.0);
    self.statusLabel.frame = CGRectMake(width - 132.0, 17.0, 116.0, 20.0);
    self.scrollView.frame = CGRectMake(padding, 52.0, width - padding * 2.0, MAX(0.0, height - 66.0));
    CGFloat contentHeight = MAX(CGRectGetHeight(self.scrollView.bounds), self.stackView.arrangedSubviews.count * 56.0);
    self.stackView.frame = CGRectMake(0, 0, CGRectGetWidth(self.scrollView.bounds), contentHeight);
    self.scrollView.contentSize = self.stackView.bounds.size;
}

- (void)dealloc {
    ++_loadGeneration;
    ++_switchGeneration;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
@end
