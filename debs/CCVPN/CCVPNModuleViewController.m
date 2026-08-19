#import "CCVPNModule.h"
#import <NetworkExtension/NetworkExtension.h>

@interface NEVPNManager (CCVPNEnumeration)
+ (void)loadAllFromPreferencesWithCompletionHandler:(void (^)(NSArray<NEVPNManager *> *, NSError *))completionHandler;
@end

static NSString *const kCCVPNNodeKey = @"com.huayuarc.ccvpn.node";

@interface CCVPNModuleViewController ()
@property(nonatomic,strong) UIView *expandedView;
@property(nonatomic,strong) UIImageView *headerIcon;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIScrollView *nodeScroll;
@property(nonatomic,strong) UIStackView *nodeStack;
@property(nonatomic,strong) NSArray<NEVPNManager *> *managers;
@property(nonatomic,assign) BOOL expandedMode;
@end

@implementation CCVPNModuleViewController

- (UIImage *)glyph { return [(CCVPNModule *)self.module iconGlyph]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    _expandedView = [UIView new]; _expandedView.hidden = YES;
    [self.view addSubview:_expandedView];
    _headerIcon = [[UIImageView alloc] initWithImage:[self glyph]];
    _headerIcon.contentMode = UIViewContentModeScaleAspectFit; _headerIcon.tintColor = UIColor.whiteColor;
    [_expandedView addSubview:_headerIcon];
    _titleLabel = [UILabel new]; _titleLabel.text = @"VPN 节点"; _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold]; [_expandedView addSubview:_titleLabel];
    _statusLabel = [UILabel new]; _statusLabel.textAlignment = NSTextAlignmentRight;
    _statusLabel.textColor = [UIColor colorWithWhite:1 alpha:.65]; _statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [_expandedView addSubview:_statusLabel];
    _nodeScroll = [UIScrollView new]; _nodeScroll.showsVerticalScrollIndicator = NO; [_expandedView addSubview:_nodeScroll];
    _nodeStack = [UIStackView new]; _nodeStack.axis = UILayoutConstraintAxisVertical; _nodeStack.spacing = 7; [_nodeScroll addSubview:_nodeStack];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(statusChanged:) name:NEVPNStatusDidChangeNotification object:nil];
    [self reloadManagers];
}
- (void)reloadManagers {
    __weak typeof(self) weakSelf = self;
    [NEVPNManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NEVPNManager *> *items, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.managers = error ? @[] : items; [weakSelf refreshState]; [weakSelf rebuildNodes]; });
    }];
}
- (NSString *)nameFor:(NEVPNManager *)m { return m.localizedDescription.length ? m.localizedDescription : @"VPN"; }
- (BOOL)isActive:(NEVPNManager *)m { NEVPNStatus s=m.connection.status; return s==NEVPNStatusConnected||s==NEVPNStatusConnecting||s==NEVPNStatusReasserting; }
- (NEVPNManager *)activeManager { for (NEVPNManager *m in self.managers) if ([self isActive:m]) return m; return nil; }
- (NEVPNManager *)preferredManager {
    NSString *name=[[NSUserDefaults standardUserDefaults] stringForKey:kCCVPNNodeKey];
    for (NEVPNManager *m in self.managers) if ([self nameFor:m] && [[self nameFor:m] isEqualToString:name]) return m;
    for (NEVPNManager *m in self.managers) if (m.enabled) return m;
    return self.managers.firstObject;
}
- (NEVPNManager *)currentManager { return self.activeManager ?: self.preferredManager; }
- (void)toggleVPN {
    NEVPNManager *m=self.currentManager;
    if (!m) { [self reloadManagers]; return; }
    if (self.activeManager) [m.connection stopVPNTunnel];
    else { NSError *error=nil; [m.connection startVPNTunnelAndReturnError:&error]; }
    [self refreshState]; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.7*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self reloadManagers];});
}
- (void)buttonTapped:(id)sender forEvent:(id)event { [self toggleVPN]; }
- (void)statusChanged:(NSNotification *)note { dispatch_async(dispatch_get_main_queue(), ^{ [self refreshState]; }); }
- (void)refreshState {
    NEVPNManager *m=self.currentManager; BOOL active=self.activeManager!=nil;
    ((CCVPNModule *)self.module).selected = active && !_expandedMode;
    _statusLabel.text = active ? [self nameFor:self.activeManager] : (m ? @"未连接" : @"未配置");
    _headerIcon.tintColor = active ? UIColor.systemBlueColor : UIColor.whiteColor;
}
- (void)rebuildNodes {
    for (UIView *v in _nodeStack.arrangedSubviews) { [_nodeStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    NSInteger i=0; for (NEVPNManager *m in self.managers) {
        UIButton *b=[UIButton buttonWithType:UIButtonTypeCustom]; b.tag=i++; b.layer.cornerRadius=13; b.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeft;
        b.titleLabel.font=[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]; [b setTitle:[self nameFor:m] forState:UIControlStateNormal];
        [b addTarget:self action:@selector(selectNode:) forControlEvents:UIControlEventTouchUpInside]; [b.heightAnchor constraintEqualToConstant:47].active=YES; [_nodeStack addArrangedSubview:b];
    }
    [self updateNodeAppearance];
}
- (void)updateNodeAppearance {
    NEVPNManager *chosen=self.currentManager;
    for (UIView *v in _nodeStack.arrangedSubviews) if ([v isKindOfClass:UIButton.class]) {
        UIButton *b=(UIButton *)v; BOOL selected=b.tag<self.managers.count&&self.managers[b.tag]==chosen;
        b.backgroundColor=selected?[UIColor colorWithRed:.12 green:.52 blue:1 alpha:.82]:[UIColor colorWithWhite:1 alpha:.10]; [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        UIImage *mark=[UIImage systemImageNamed:selected?@"checkmark.circle.fill":@"circle"]; [b setImage:[mark imageWithTintColor:[UIColor colorWithWhite:1 alpha:selected?1:.45] renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
    }
}
- (void)selectNode:(UIButton *)button {
    if (button.tag>=self.managers.count) return; NEVPNManager *m=self.managers[button.tag]; NEVPNManager *active=self.activeManager;
    if (active&&active!=m) [active.connection stopVPNTunnel]; [[NSUserDefaults standardUserDefaults] setObject:[self nameFor:m] forKey:kCCVPNNodeKey];
    [self refreshState]; [self updateNodeAppearance];
}
- (BOOL)shouldBeginTransitionToExpandedContentModule { return YES; }
- (BOOL)shouldFinishTransitionToExpandedContentModule { return YES; }
- (void)willTransitionToExpandedContentMode:(BOOL)animated { _expandedMode=YES; _expandedView.hidden=NO; ((CCVPNModule *)self.module).selected=NO; [self reloadManagers]; }
- (void)willReturnToExpandedContentModule { _expandedMode=NO; _expandedView.hidden=YES; [self refreshState]; }
- (CGFloat)preferredExpandedContentHeight { return 330; }
- (CGFloat)preferredExpandedContentWidth { return MIN(MAX(CGRectGetWidth(UIScreen.mainScreen.bounds)-40,300),370); }
- (BOOL)providesOwnPlatter { return NO; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews]; CGRect b=self.view.bounds; CGFloat w=CGRectGetWidth(b),h=CGRectGetHeight(b); _expandedView.frame=b;
    BOOL expanded=_expandedMode&&w>=220&&h>=180; _expandedView.hidden=!expanded;
    if (!expanded) { _expandedMode=NO; [self refreshState]; return; }
    CGFloat pad=16; _headerIcon.frame=CGRectMake(pad,14,30,30); _titleLabel.frame=CGRectMake(54,12,w-155,24); _statusLabel.frame=CGRectMake(w-104,14,88,22);
    _nodeScroll.frame=CGRectMake(pad,52,w-pad*2,MAX(0,h-64)); _nodeStack.frame=CGRectMake(0,0,CGRectGetWidth(_nodeScroll.bounds),MAX(CGRectGetHeight(_nodeScroll.bounds),_nodeStack.arrangedSubviews.count*54)); _nodeScroll.contentSize=_nodeStack.bounds.size;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
