#import "VPNNodeModule.h"
#import "VPNBridge.h"

@interface VPNNodeViewController ()
@property(nonatomic,strong) UIView *panel;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIScrollView *scrollView;
@property(nonatomic,strong) UIStackView *stackView;
@property(nonatomic,strong) NSArray<NSDictionary *> *nodes;
@property(nonatomic,assign) BOOL expanded;
@property(nonatomic,assign) BOOL hostVisible;
@property(nonatomic,assign) NSUInteger loadGeneration;
@property(nonatomic,assign) NSUInteger pollGeneration;
@end

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
    self.nodes = @[];
}

- (BOOL)isExpanded { return self.expanded; }

- (void)hostWillAppear {
    self.hostVisible = YES;
    [self.module refreshVisualState];
    [self beginVisiblePolling];
}
- (void)hostDidDisappear {
    self.hostVisible = NO;
    self.expanded = NO;
    ++self.pollGeneration;
}

- (void)beginVisiblePolling {
    NSUInteger generation = ++self.pollGeneration;
    __weak typeof(self) weakSelf = self;
    NSArray<NSNumber *> *delays = @[@0.0, @0.12, @0.3, @0.6, @1.0, @1.5, @2.1, @2.8, @3.6, @4.5];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) selfRef = weakSelf;
            if (!selfRef || generation != selfRef.pollGeneration || !selfRef.hostVisible) return;
            [selfRef.module refreshVisualState];
            if (selfRef.expanded) [selfRef updateEverything];
        });
    }
}

- (void)attemptNodeLoadForGeneration:(NSUInteger)generation attempt:(NSUInteger)attempt {
    if (generation != self.loadGeneration || !self.expanded) return;
    NSArray<NSDictionary *> *items = @[];
    @try { items = VPNLegacyCopyNodes() ?: @[]; }
    @catch (__unused NSException *exception) { items = @[]; }
    if (items.count || attempt >= 3) {
        self.nodes = items;
        [self updateEverything];
        [self.view setNeedsLayout];
        return;
    }
    NSArray<NSNumber *> *delays = @[@0.2, @0.4, @0.6];
    NSTimeInterval delay = delays[attempt].doubleValue;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf attemptNodeLoadForGeneration:generation attempt:attempt + 1];
    });
}

- (void)reloadNodesSafely {
    NSUInteger generation = ++self.loadGeneration;
    self.statusLabel.text = @"读取中";
    self.nodes = @[];
    [self rebuildRows];
    [self attemptNodeLoadForGeneration:generation attempt:0];
}

- (NSDictionary *)selectedNode {
    for (NSDictionary *node in self.nodes) if ([node[@"active"] boolValue]) return node;
    return self.nodes.firstObject;
}

- (void)updateEverything {
    BOOL active = VPNLegacyIsActive();
    self.statusLabel.text = active ? @"已连接" : (self.nodes.count ? @"未连接" : @"无 VPN 配置");
    [self rebuildRows];
}

- (void)rebuildRows {
    for (UIView *view in self.stackView.arrangedSubviews.copy) {
        [self.stackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSDictionary *selectedNode = [self selectedNode];
    if (self.nodes.count == 0) {
        UILabel *label = [UILabel new];
        label.text = @"未读取到 VPN 节点";
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.secondaryLabelColor;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        [label.heightAnchor constraintEqualToConstant:56].active = YES;
        [self.stackView addArrangedSubview:label];
        return;
    }
    [self.nodes enumerateObjectsUsingBlock:^(NSDictionary *node, NSUInteger index, BOOL *stop) {
        NSString *name = [node[@"name"] isKindOfClass:NSString.class] ? node[@"name"] : @"VPN";
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = (NSInteger)index;
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        button.layer.cornerRadius = 12;
        button.clipsToBounds = YES;
        [button setTitle:[NSString stringWithFormat:@"    %@", name] forState:UIControlStateNormal];
        BOOL selected = node == selectedNode;
        UIImage *mark = [UIImage systemImageNamed:selected ? @"checkmark.circle.fill" : @"circle"];
        [button setImage:mark forState:UIControlStateNormal];
        button.tintColor = selected ? UIColor.systemBlueColor : UIColor.tertiaryLabelColor;
        button.backgroundColor = selected ? [UIColor.systemBlueColor colorWithAlphaComponent:0.14] : UIColor.secondarySystemFillColor;
        [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
        [button addTarget:self action:@selector(nodeTapped:) forControlEvents:UIControlEventTouchUpInside];
        [button.heightAnchor constraintEqualToConstant:48].active = YES;
        [self.stackView addArrangedSubview:button];
    }];
}

- (void)nodeTapped:(UIButton *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= self.nodes.count) return;
    NSDictionary *node = self.nodes[(NSUInteger)sender.tag];
    NSString *serviceID = node[@"id"];
    NSUInteger grade = [node[@"grade"] unsignedIntegerValue];
    if (!VPNLegacySelectNode(serviceID, grade)) {
        self.statusLabel.text = @"选择失败";
        return;
    }
    NSMutableArray *updated = [NSMutableArray arrayWithCapacity:self.nodes.count];
    for (NSDictionary *item in self.nodes) {
        NSMutableDictionary *copy = item.mutableCopy;
        copy[@"active"] = @([item[@"id"] isEqualToString:serviceID]);
        [updated addObject:copy.copy];
    }
    self.nodes = updated.copy;
    self.statusLabel.text = @"已选择";
    [self rebuildRows];
    [self.module refreshVisualState];
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
    [self reloadNodesSafely];
    [self.view setNeedsLayout];
}
- (void)willReturnToExpandedContentModule {
    self.expanded = NO;
    ++self.loadGeneration;
    [self.module refreshVisualState];
    [self.view setNeedsLayout];
}
- (CGFloat)preferredExpandedContentHeight { return 360.0; }
- (CGFloat)preferredExpandedContentWidth {
    return MAX(MIN(CGRectGetWidth(UIScreen.mainScreen.bounds) - 32.0, 390.0), 300.0);
}
- (BOOL)providesOwnPlatter { return NO; }

- (void)hostDidLayoutWithBounds:(CGRect)bounds {
    self.view.frame = bounds;
    CGFloat width = CGRectGetWidth(bounds), height = CGRectGetHeight(bounds);
    BOOL roomy = width >= 220.0 && height >= 180.0;
    if (roomy && !self.expanded) {
        self.expanded = YES;
        [self reloadNodesSafely];
    } else if (!roomy && self.expanded) {
        self.expanded = NO;
        ++self.loadGeneration;
        self.nodes = @[];
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
}
@end
