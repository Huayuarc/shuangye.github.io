#import "VPNNodeModule.h"
#import "VPNBridge.h"
#import <NetworkExtension/NetworkExtension.h>
#import <objc/message.h>

@interface NEVPNManager (VPNNodeSafeEnumeration)
+ (void)loadAllFromPreferencesWithCompletionHandler:(void (^)(NSArray<NEVPNManager *> *, NSError *))handler;
@property(nonatomic,readonly) NSUUID *identifier;
@property(nonatomic,readonly) id configuration;
@end

static NSString *const VPNPreferredNameKey = @"com.huayuarc.vpnnodeselector.preferredName";
static NSString *const VPNSharedDomain = @"com.huayuarc.vpnnodeselector.shared";
static NSString *const VPNSelectedNameKey = @"SelectedName";
static NSString *const VPNRequestedNameKey = @"RequestedName";
static CFStringRef const VPNSelectionChangedNotification = CFSTR("com.huayuarc.vpnnodeselector.selection-changed");
static CFStringRef const VPNSelectionRequestNotification = CFSTR("com.huayuarc.vpnnodeselector.selection-request");

static NSString *VPNSharedSelectedName(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VPNSharedDomain);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)VPNSelectedNameKey, (__bridge CFStringRef)VPNSharedDomain));
}

static void VPNRequestSystemSelection(NSString *name) {
    if (!name.length) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)VPNRequestedNameKey, (__bridge CFStringRef)name, (__bridge CFStringRef)VPNSharedDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)VPNSharedDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), VPNSelectionRequestNotification, NULL, NULL, true);
}

@interface VPNNodeViewController ()
@property(nonatomic,strong) UIView *panel;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIScrollView *scrollView;
@property(nonatomic,strong) UIStackView *stackView;
@property(nonatomic,strong) NSArray<NEVPNManager *> *managers;
@property(nonatomic,assign) BOOL expanded;
@property(nonatomic,assign) BOOL hostVisible;
@property(nonatomic,assign) NSUInteger loadGeneration;
@property(nonatomic,assign) NSUInteger pollGeneration;
@property(nonatomic,assign) NSUInteger switchGeneration;
@property(nonatomic,assign) NSUInteger compactToggleGeneration;
@property(nonatomic,assign) NSUInteger startRetryGeneration;
@property(nonatomic,copy) NSString *systemSelectedName;
@property(nonatomic,strong) NSMutableDictionary<NSString *, NSString *> *managerNameSnapshot;
@property(nonatomic,strong) NEVPNManager *pendingManager;
@end

static void VPNControllerSelectionDidChange(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    VPNNodeViewController *controller = (__bridge VPNNodeViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [controller refreshForExternalVPNChange]; });
}

@implementation VPNNodeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
    _panel = [UIView new];
    _panel.backgroundColor = UIColor.clearColor;
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
    _scrollView.backgroundColor = UIColor.clearColor;
    _scrollView.showsVerticalScrollIndicator = YES;
    [_panel addSubview:_scrollView];
    _stackView = [UIStackView new];
    _stackView.backgroundColor = UIColor.clearColor;
    _stackView.axis = UILayoutConstraintAxisVertical;
    _stackView.spacing = 8;
    [_scrollView addSubview:_stackView];
    self.managers = @[];
    self.managerNameSnapshot = [NSMutableDictionary dictionary];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self, VPNControllerSelectionDidChange, VPNSelectionChangedNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vpnStatusChanged:) name:NEVPNStatusDidChangeNotification object:nil];
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self, VPNSelectionChangedNotification, NULL);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isExpanded { return self.expanded; }
- (BOOL)isFriendlyManagerName:(NSString *)name {
    if (name.length == 0) return NO;
    NSString *lower = name.lowercaseString;
    return ![lower hasPrefix:@"com.apple."] && ![lower containsString:@"cellularusage"];
}
- (NSString *)keyForManager:(NEVPNManager *)manager {
    id identifier = [self identifierForManager:manager];
    if ([identifier respondsToSelector:@selector(UUIDString)]) return [identifier UUIDString];
    return [NSString stringWithFormat:@"%p", manager];
}
- (NSString *)nameForManager:(NEVPNManager *)manager {
    NSString *key = [self keyForManager:manager];
    NSString *snapshot = self.managerNameSnapshot[key];
    if (snapshot.length) return snapshot;
    NSString *live = manager.localizedDescription;
    if ([self isFriendlyManagerName:live]) {
        self.managerNameSnapshot[key] = live;
        return live;
    }
    return @"VPN";
}
- (NSArray<NEVPNManager *> *)filteredManagersFromItems:(NSArray<NEVPNManager *> *)items {
    NSArray<NSString *> *allowed = VPNSafeCurrentPersonalVPNDisplayNames();
    if (allowed.count == 0) {
        NSMutableArray *safe = [NSMutableArray array];
        for (NEVPNManager *manager in items ?: @[]) if ([self isFriendlyManagerName:manager.localizedDescription]) [safe addObject:manager];
        return safe;
    }
    NSMutableArray<NEVPNManager *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *used = [NSMutableSet set];
    for (NEVPNManager *manager in items ?: @[]) {
        NSString *key = [self keyForManager:manager];
        NSString *live = manager.localizedDescription;
        if ([self isFriendlyManagerName:live] && [allowed containsObject:live]) {
            self.managerNameSnapshot[key] = live;
            [used addObject:live];
            [result addObject:manager];
        }
    }
    for (NEVPNManager *manager in items ?: @[]) {
        if ([result containsObject:manager]) continue;
        NSString *key = [self keyForManager:manager];
        NSString *snapshot = self.managerNameSnapshot[key];
        if (snapshot.length && [allowed containsObject:snapshot]) {
            [used addObject:snapshot];
            [result addObject:manager];
        }
    }
    return result;
}
- (BOOL)isActiveStatus:(NEVPNStatus)status { return status == NEVPNStatusConnected || status == NEVPNStatusConnecting || status == NEVPNStatusReasserting; }
- (NEVPNManager *)activeManager { for (NEVPNManager *manager in self.managers) if ([self isActiveStatus:manager.connection.status]) return manager; return nil; }
- (NSInteger)gradeForManager:(NEVPNManager *)manager {
    id configuration = nil;
    @try { configuration = manager.configuration; } @catch (__unused NSException *exception) {}
    SEL selector = NSSelectorFromString(@"grade");
    if (configuration && [configuration respondsToSelector:selector]) {
        @try { return ((NSInteger (*)(id, SEL))objc_msgSend)(configuration, selector); }
        @catch (__unused NSException *exception) {}
    }
    return 0;
}
- (id)identifierForManager:(NEVPNManager *)manager {
    @try { return manager.identifier; } @catch (__unused NSException *exception) { return nil; }
}
- (void)refreshSystemSelectedName {
    self.systemSelectedName = VPNSharedSelectedName();
    if (self.systemSelectedName.length) return;
    self.systemSelectedName = VPNSafeCurrentSpecifierName();
    if (self.systemSelectedName.length) return;
    NSMutableDictionary<NSNumber *, id> *activeByGrade = [NSMutableDictionary dictionary];
    for (NEVPNManager *manager in self.managers) {
        NSInteger grade = [self gradeForManager:manager];
        NSNumber *key = @(grade);
        id activeID = activeByGrade[key];
        if (!activeID) {
            activeID = VPNSafeCurrentIdentifierForGrade(grade);
            if (activeID) activeByGrade[key] = activeID;
        }
        id identifier = [self identifierForManager:manager];
        if (identifier && activeID && [identifier isEqual:activeID]) {
            self.systemSelectedName = [self nameForManager:manager];
            return;
        }
    }
}
- (NEVPNManager *)preferredManager {
    if (self.systemSelectedName.length) for (NEVPNManager *manager in self.managers) if ([[self nameForManager:manager] isEqualToString:self.systemSelectedName]) return manager;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:VPNPreferredNameKey];
    if (saved.length) for (NEVPNManager *manager in self.managers) if ([[self nameForManager:manager] isEqualToString:saved]) return manager;
    for (NEVPNManager *manager in self.managers) if (manager.enabled) return manager;
    return self.managers.firstObject;
}
- (NEVPNManager *)selectedManager { return self.activeManager ?: self.preferredManager; }
- (BOOL)hasLoadedManagers { return self.managers.count > 0; }
- (BOOL)hasActiveManager { return self.activeManager != nil; }

- (void)applyCompactToggleWithManagers:(NSArray<NEVPNManager *> *)items generation:(NSUInteger)generation {
    if (generation != self.compactToggleGeneration) return;
    self.managers = [self filteredManagersFromItems:(items ?: @[])];
    [self refreshSystemSelectedName];
    NEVPNManager *active = self.activeManager;
    if (active) {
        [[NSUserDefaults standardUserDefaults] setObject:[self nameForManager:active] forKey:VPNPreferredNameKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    self.pendingManager = nil;
    ++self.switchGeneration;
    if (active) {
        [active.connection stopVPNTunnel];
        self.statusLabel.text = @"正在断开…";
    } else {
        NEVPNManager *target = self.preferredManager;
        if (!target) {
            self.statusLabel.text = @"无 VPN 配置";
        } else {
            NSError *error = nil;
            [target.connection startVPNTunnelAndReturnError:&error];
            self.statusLabel.text = error ? @"连接失败" : @"连接中…";
        }
    }
    [self.module refreshVisualState];
    [self beginVisiblePolling];
}

- (void)togglePreferredManager {
    NSUInteger generation = ++self.compactToggleGeneration;
    __weak typeof(self) weakSelf = self;
    [NEVPNManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NEVPNManager *> *items, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) selfRef = weakSelf;
            if (!selfRef) return;
            [selfRef applyCompactToggleWithManagers:(error ? @[] : items) generation:generation];
        });
    }];
}

- (void)hostWillAppear {
    self.hostVisible = YES;
    [self.module refreshVisualState];
    [self beginVisiblePolling];
}
- (void)hostDidDisappear {
    self.hostVisible = NO;
    self.expanded = NO;
    ++self.loadGeneration;
    ++self.pollGeneration;
}

- (void)beginVisiblePolling {
    NSUInteger generation = ++self.pollGeneration;
    __weak typeof(self) weakSelf = self;
    for (NSNumber *delay in @[@0.0, @0.15, @0.4, @0.8, @1.4, @2.2, @3.2, @4.5]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) selfRef = weakSelf;
            if (!selfRef || generation != selfRef.pollGeneration || !selfRef.hostVisible) return;
            [selfRef.module refreshVisualState];
            if (selfRef.expanded) [selfRef updateEverything];
        });
    }
}

- (void)reloadManagersSafely {
    NSUInteger generation = ++self.loadGeneration;
    self.statusLabel.text = @"读取中";
    self.managers = @[];
    [self rebuildRows];
    __weak typeof(self) weakSelf = self;
    [NEVPNManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NEVPNManager *> *items, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) selfRef = weakSelf;
            if (!selfRef || generation != selfRef.loadGeneration || !selfRef.expanded) return;
            selfRef.managers = error ? @[] : [selfRef filteredManagersFromItems:(items ?: @[])];
            [selfRef refreshSystemSelectedName];
            NEVPNManager *active = selfRef.activeManager;
            if (active) {
                [[NSUserDefaults standardUserDefaults] setObject:[selfRef nameForManager:active] forKey:VPNPreferredNameKey];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
            [selfRef updateEverything];
            [selfRef.view setNeedsLayout];
        });
    }];
}

- (void)updateEverything {
    NEVPNManager *active = self.activeManager;
    self.statusLabel.text = active ? [self nameForManager:active] : (self.managers.count ? @"未连接" : @"无 VPN 配置");
    [self rebuildRows];
}

- (void)rebuildRows {
    for (UIView *view in self.stackView.arrangedSubviews.copy) {
        [self.stackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NEVPNManager *selected = self.selectedManager;
    if (self.managers.count == 0) {
        UILabel *label = [UILabel new];
        label.text = @"未读取到 VPN 节点";
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.secondaryLabelColor;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        [label.heightAnchor constraintEqualToConstant:56].active = YES;
        [self.stackView addArrangedSubview:label];
        return;
    }
    [self.managers enumerateObjectsUsingBlock:^(NEVPNManager *manager, NSUInteger index, BOOL *stop) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = (NSInteger)index;
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        button.layer.cornerRadius = 12;
        button.clipsToBounds = YES;
        [button setTitle:[NSString stringWithFormat:@"    %@", [self nameForManager:manager]] forState:UIControlStateNormal];
        BOOL on = manager == selected;
        [button setImage:[UIImage systemImageNamed:on ? @"checkmark.circle.fill" : @"circle"] forState:UIControlStateNormal];
        button.tintColor = on ? UIColor.systemBlueColor : UIColor.tertiaryLabelColor;
        button.backgroundColor = on ? [UIColor.systemBlueColor colorWithAlphaComponent:0.14] : UIColor.secondarySystemFillColor;
        [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
        [button addTarget:self action:@selector(nodeTapped:) forControlEvents:UIControlEventTouchUpInside];
        [button.heightAnchor constraintEqualToConstant:48].active = YES;
        [self.stackView addArrangedSubview:button];
    }];
}

- (void)startPendingManagerForGeneration:(NSUInteger)generation {
    if (generation != self.switchGeneration || !self.pendingManager) return;
    NEVPNManager *target = self.pendingManager;
    self.pendingManager = nil;
    NSError *error = nil;
    [target.connection startVPNTunnelAndReturnError:&error];
    self.statusLabel.text = error ? @"刷新配置…" : @"连接中…";
    [self rebuildRows];
    if (error) {
        NSUInteger retry = ++self.startRetryGeneration;
        __weak typeof(self) weakSelf = self;
        [target loadFromPreferencesWithCompletionHandler:^(NSError *loadError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) selfRef = weakSelf;
                if (!selfRef || retry != selfRef.startRetryGeneration || generation != selfRef.switchGeneration || loadError) return;
                NSError *retryError = nil;
                [target.connection startVPNTunnelAndReturnError:&retryError];
                selfRef.statusLabel.text = retryError ? @"切换失败" : @"连接中…";
                [selfRef rebuildRows];
            });
        }];
    }
}

- (void)nodeTapped:(UIButton *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= self.managers.count) return;
    NEVPNManager *target = self.managers[(NSUInteger)sender.tag];
    NEVPNManager *active = self.activeManager;
    NSString *targetName = [self nameForManager:target];
    [[NSUserDefaults standardUserDefaults] setObject:targetName forKey:VPNPreferredNameKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    VPNRequestSystemSelection(targetName);
    BOOL specifierSelected = VPNSafeSelectPersonalVPNSpecifierNamed(targetName);
    id targetIdentifier = [self identifierForManager:target];
    NSInteger targetGrade = [self gradeForManager:target];
    BOOL identifierSelected = targetIdentifier && VPNSafeSetCurrentIdentifier(targetIdentifier, targetGrade);
    if (specifierSelected || identifierSelected) {
        self.systemSelectedName = targetName;
    }
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
    NSUInteger generation = ++self.switchGeneration;
    if (active && active != target) {
        self.pendingManager = target;
        self.statusLabel.text = @"正在切换…";
        [active.connection stopVPNTunnel];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf startPendingManagerForGeneration:generation];
        });
    } else if (!active) {
        self.pendingManager = target;
        [self startPendingManagerForGeneration:generation];
    } else {
        self.statusLabel.text = @"已连接";
    }
    [self rebuildRows];
}

- (void)vpnStatusChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pendingManager && !self.activeManager) [self startPendingManagerForGeneration:self.switchGeneration];
        if (self.expanded) [self updateEverything];
        [self.module refreshVisualState];
    });
}

- (void)refreshForExternalVPNChange {
    [self.module refreshVisualState];
    if (self.expanded) [self updateEverything];
    if (self.hostVisible) [self beginVisiblePolling];
}

- (BOOL)shouldBeginTransitionToExpandedContentModule { return YES; }
- (BOOL)shouldFinishTransitionToExpandedContentModule { return YES; }
- (void)willTransitionToExpandedContentMode:(BOOL)animated {
    self.expanded = YES;
    [self reloadManagersSafely];
    [self.view setNeedsLayout];
}
- (void)willReturnToExpandedContentModule {
    self.expanded = NO;
    ++self.loadGeneration;
    [self.module refreshVisualState];
    [self.view setNeedsLayout];
}
- (CGFloat)preferredExpandedContentHeight { return 360.0; }
- (CGFloat)preferredExpandedContentWidth { return MAX(MIN(CGRectGetWidth(UIScreen.mainScreen.bounds) - 32.0, 390.0), 300.0); }
- (BOOL)providesOwnPlatter { return NO; }

- (void)hostDidLayoutWithBounds:(CGRect)bounds {
    self.view.frame = bounds;
    CGFloat width = CGRectGetWidth(bounds), height = CGRectGetHeight(bounds);
    BOOL roomy = width >= 220.0 && height >= 180.0;
    if (roomy && !self.expanded) {
        self.expanded = YES;
        [self reloadManagersSafely];
    } else if (!roomy && self.expanded) {
        self.expanded = NO;
        ++self.loadGeneration;
    }
    self.panel.frame = self.view.bounds;
    CGFloat padding = 16.0;
    self.titleLabel.frame = CGRectMake(padding, 14.0, width - 150.0, 27.0);
    self.statusLabel.frame = CGRectMake(width - 132.0, 17.0, 116.0, 20.0);
    self.scrollView.frame = CGRectMake(padding, 52.0, width - padding * 2.0, MAX(0.0, height - 66.0));
    CGFloat contentHeight = MAX(CGRectGetHeight(self.scrollView.bounds), self.stackView.arrangedSubviews.count * 56.0);
    self.stackView.frame = CGRectMake(0, 0, CGRectGetWidth(self.scrollView.bounds), contentHeight);
    self.scrollView.contentSize = self.stackView.bounds.size;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self hostDidLayoutWithBounds:self.view.bounds];
}

- (void)dealloc {
    ++_loadGeneration;
    ++_pollGeneration;
    ++_switchGeneration;
    ++_compactToggleGeneration;
    ++_startRetryGeneration;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
@end
