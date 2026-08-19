#import "VPNNodeModule.h"
#import "VPNBridge.h"

static NSString *const VPNPreferredNameKey = @"com.huayuarc.vpnnodeselector.preferredName";

@interface VPNNodeViewController ()
@property(nonatomic,strong) UIView *panel;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIScrollView *scrollView;
@property(nonatomic,strong) UIStackView *stackView;
@property(nonatomic,strong) NSArray<NSString *> *nodes;
@property(nonatomic,assign) BOOL expanded;
@property(nonatomic,assign) NSUInteger loadGeneration;
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
    self.nodes = @[];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (CGRectGetWidth(self.view.bounds) < 220 || CGRectGetHeight(self.view.bounds) < 180) self.expanded = NO;
    [self refreshForExternalVPNChange];
}

- (BOOL)validNodeName:(NSString *)name {
    if (![name isKindOfClass:NSString.class]) return NO;
    NSString *trim = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trim.length == 0 || trim.length > 64) return NO;
    if ([trim containsString:@"/"] || [trim containsString:@"{"] || [trim containsString:@"}"]) return NO;
    NSArray *deny = @[@"VPN", @"IPv4", @"IPv6", @"DNS", @"Plugin", @"PacketTunnel", @"AppProxy"];
    for (NSString *item in deny) if ([trim isEqualToString:item]) return NO;
    return YES;
}

- (void)addCandidate:(id)value to:(NSMutableOrderedSet<NSString *> *)set {
    if (![value isKindOfClass:NSString.class]) return;
    NSString *name = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([self validNodeName:name]) [set addObject:name];
}

- (void)scanObject:(id)object into:(NSMutableOrderedSet<NSString *> *)set depth:(NSUInteger)depth {
    if (!object || depth > 8) return;
    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = object;
        for (NSString *key in @[@"localizedDescription", @"UserDefinedName", @"displayName", @"name", @"Name"]) {
            [self addCandidate:dict[key] to:set];
        }
        NSDictionary *interface = dict[@"Interface"];
        if ([interface isKindOfClass:NSDictionary.class]) [self addCandidate:interface[@"UserDefinedName"] to:set];
        for (id value in dict.allValues) [self scanObject:value into:set depth:depth + 1];
    } else if ([object isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)object) [self scanObject:value into:set depth:depth + 1];
    }
}

- (NSArray<NSString *> *)readNodesFromSystemPreferences {
    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];
    NSArray<NSString *> *paths = @[
        @"/var/preferences/SystemConfiguration/preferences.plist",
        @"/private/var/preferences/SystemConfiguration/preferences.plist",
        @"/var/mobile/Library/Preferences/com.apple.networkextension.plist",
        @"/private/var/mobile/Library/Preferences/com.apple.networkextension.plist"
    ];
    for (NSString *path in paths) {
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
        if (plist) [self scanObject:plist into:set depth:0];
    }
    return set.array;
}

- (void)reloadNodesSafely {
    NSUInteger generation = ++self.loadGeneration;
    self.statusLabel.text = @"读取中";
    self.nodes = @[];
    [self rebuildRows];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<NSString *> *nodes = @[];
        @try { nodes = [weakSelf readNodesFromSystemPreferences] ?: @[]; }
        @catch (__unused NSException *exception) { nodes = @[]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) selfRef = weakSelf;
            if (!selfRef || generation != selfRef.loadGeneration) return;
            selfRef.nodes = nodes;
            [selfRef updateEverything];
        });
    });
}

- (NSString *)chosenName {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:VPNPreferredNameKey];
    if (saved.length) return saved;
    return self.nodes.firstObject;
}

- (void)updateEverything {
    BOOL active = VPNLegacyIsActive();
    self.statusLabel.text = active ? @"已连接" : (self.nodes.count ? @"未连接" : @"未读取到配置");
    [self rebuildRows];
}

- (void)rebuildRows {
    for (UIView *view in self.stackView.arrangedSubviews.copy) {
        [self.stackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSString *chosen = [self chosenName];
    if (self.nodes.count == 0) {
        UILabel *label = [UILabel new];
        label.text = @"未读取到节点；可先进入 设置 > VPN 确认配置存在";
        label.numberOfLines = 2;
        label.textColor = UIColor.secondaryLabelColor;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        [label.heightAnchor constraintEqualToConstant:56].active = YES;
        [self.stackView addArrangedSubview:label];
        return;
    }
    [self.nodes enumerateObjectsUsingBlock:^(NSString *name, NSUInteger index, BOOL *stop) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = (NSInteger)index;
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        button.layer.cornerRadius = 12;
        button.clipsToBounds = YES;
        [button setTitle:[NSString stringWithFormat:@"    %@", name] forState:UIControlStateNormal];
        BOOL selected = [name isEqualToString:chosen];
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
    if (sender.tag < 0 || (NSUInteger)sender.tag >= self.nodes.count) return;
    NSString *name = self.nodes[(NSUInteger)sender.tag];
    [[NSUserDefaults standardUserDefaults] setObject:name forKey:VPNPreferredNameKey];
    self.statusLabel.text = VPNLegacyIsActive() ? @"已连接" : @"已选择";
    [self rebuildRows];
}

- (void)refreshForExternalVPNChange {
    [self.module refreshState];
    if (self.expanded) [self updateEverything];
}

- (void)buttonTapped:(id)sender forEvent:(id)event {
    if (!self.expanded) {
        VPNLegacyToggle();
        __weak typeof(self) weakSelf = self;
        NSArray<NSNumber *> *delays = @[@0.15, @0.45, @0.9, @1.8];
        for (NSNumber *delay in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf refreshForExternalVPNChange];
            });
        }
    }
}

- (BOOL)shouldBeginTransitionToExpandedContentModule { return YES; }
- (BOOL)shouldFinishTransitionToExpandedContentModule { return YES; }
- (void)willTransitionToExpandedContentMode:(BOOL)animated {
    self.expanded = YES;
    self.panel.hidden = NO;
    [self reloadNodesSafely];
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

- (void)dealloc { ++_loadGeneration; }
@end
