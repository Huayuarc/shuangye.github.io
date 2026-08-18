#import "VPNControlCenterModule.h"
#import <NetworkExtension/NetworkExtension.h>

@interface VPNControlCenterModuleViewController ()
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) UIImageView *glyphView;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *stateLabel;
@property(nonatomic,strong) NSArray<NEVPNManager *> *managers;
@end

@implementation VPNControlCenterModuleViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    _button = [UIButton buttonWithType:UIButtonTypeCustom];
    _button.frame = self.view.bounds;
    _button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_button addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_button];

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
    _glyphView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"vpn" withConfiguration:config]];
    _glyphView.contentMode = UIViewContentModeScaleAspectFit;
    [_button addSubview:_glyphView];
    _titleLabel = [UILabel new]; _titleLabel.text = @"VPN"; _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.adjustsFontSizeToFitWidth = YES; _titleLabel.minimumScaleFactor = .6;
    [_button addSubview:_titleLabel];
    _stateLabel = [UILabel new]; _stateLabel.textAlignment = NSTextAlignmentCenter;
    _stateLabel.adjustsFontSizeToFitWidth = YES; _stateLabel.minimumScaleFactor = .55;
    [_button addSubview:_stateLabel];
    [self reloadManagers];
}

- (void)reloadManagers {
    __weak typeof(self) weakSelf = self;
    [NEVPNManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NEVPNManager *> *managers, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.managers = error ? @[] : managers;
            [weakSelf refreshState];
        });
    }];
}

- (NEVPNManager *)selectedManager {
    for (NEVPNManager *manager in self.managers) if (manager.isEnabled) return manager;
    return self.managers.firstObject;
}
- (BOOL)isConnected {
    NEVPNStatus status = self.selectedManager.connection.status;
    return status == NEVPNStatusConnected || status == NEVPNStatusConnecting || status == NEVPNStatusReasserting;
}
- (NSString *)displayNameForManager:(NEVPNManager *)manager {
    NSString *name = manager.localizedDescription;
    return name.length ? name : @"VPN";
}

- (void)toggle:(id)sender {
    NEVPNManager *manager = [self selectedManager];
    if (!manager) { [self refreshState]; return; }
    NSError *error = nil;
    if ([self isConnected]) [manager.connection stopVPNTunnel];
    else [manager.connection startVPNTunnelAndReturnError:&error];
    if (error) { [self refreshState]; return; }
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    [self refreshState];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self reloadManagers]; });
}

- (void)refreshState {
    NEVPNManager *manager = [self selectedManager];
    BOOL connected = [self isConnected];
    BOOL busy = manager.connection.status == NEVPNStatusConnecting || manager.connection.status == NEVPNStatusReasserting;
    _button.enabled = manager != nil;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
    UIImage *glyph = [UIImage systemImageNamed:@"vpn" withConfiguration:cfg];
    UIColor *color = connected ? UIColor.systemGreenColor : [UIColor colorWithWhite:1 alpha:.72];
    _glyphView.image = [glyph imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    _titleLabel.textColor = [UIColor colorWithWhite:1 alpha:connected ? 1 : .82];
    _stateLabel.textColor = [UIColor colorWithWhite:1 alpha:connected ? .78 : .58];
    _stateLabel.text = !manager ? @"未配置" : (busy ? @"连接中…" : (connected ? @"已连接" : @"未连接"));
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadManagers]; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; CGFloat w = CGRectGetWidth(b), h = CGRectGetHeight(b);
    _button.frame = b; BOOL compact = w < 150 && h < 150;
    CGFloat icon = compact ? 24 : 38, titleH = compact ? 15 : 24, stateH = compact ? 12 : 19, gap = compact ? 2 : 7;
    CGFloat y = floor(MAX(compact ? 5 : 10, (h - icon - gap - titleH - stateH) / 2));
    CGFloat inset = compact ? 3 : 18;
    _glyphView.frame = CGRectIntegral(CGRectMake((w-icon)/2, y, icon, icon)); y += icon + gap;
    _titleLabel.frame = CGRectIntegral(CGRectMake(inset, y, w-inset*2, titleH)); y += titleH;
    _stateLabel.frame = CGRectIntegral(CGRectMake(inset, y, w-inset*2, stateH));
    _titleLabel.font = [UIFont systemFontOfSize:compact ? 10 : 16 weight:UIFontWeightSemibold];
    _stateLabel.font = [UIFont systemFontOfSize:compact ? 8 : 12 weight:UIFontWeightRegular];
}

- (BOOL)shouldBeginTransitionToExpandedContentModule { return YES; }
- (void)willTransitionToExpandedContentMode:(BOOL)animated { [self presentNodePicker]; }
- (void)willReturnToExpandedContentModule { [self reloadManagers]; }
- (CGFloat)preferredExpandedContentHeight { return 180; }
- (CGFloat)preferredExpandedContentWidth { return MIN(MAX(CGRectGetWidth(UIScreen.mainScreen.bounds)-48, 240), 340); }
- (BOOL)providesOwnPlatter { return NO; }

- (void)presentNodePicker {
    [self reloadManagers];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择 VPN 节点" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NEVPNManager *manager in self.managers) {
        NSString *name = [self displayNameForManager:manager];
        BOOL selected = manager == [self selectedManager];
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@%@", selected ? @"✓ " : @"", name] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            for (NEVPNManager *item in self.managers) item.enabled = (item == manager);
            [manager saveToPreferencesWithCompletionHandler:^(__unused NSError *error) { [self reloadManagers]; }];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *host = self;
    while (host.presentedViewController) host = host.presentedViewController;
    [host presentViewController:sheet animated:YES completion:nil];
}
@end
