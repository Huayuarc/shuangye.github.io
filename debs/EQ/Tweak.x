#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import "EQPrefs.h"

// ============================================================
// 全屏地震警报视图控制器
// ============================================================
@interface EQAlertViewController : UIViewController
@property (nonatomic, strong) NSDictionary *eventData;
- (void)showAlert;
- (void)dismissAlert;
@end

@implementation EQAlertViewController {
    UILabel *_magnitudeLabel;
    UIButton *_dismissButton;
    SystemSoundID _soundID;
    BOOL _isDismissing;
}

- (void)dealloc {
    if (_soundID) AudioServicesDisposeSystemSoundID(_soundID);
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupUI];
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskLandscape;
}

// ============================================================
// UI 构建
// ============================================================
- (void)setupUI {
    self.view.backgroundColor = [UIColor blackColor];

    // 红色渐变背景
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = self.view.bounds;
    gradient.colors = @[
        (id)[UIColor colorWithRed:0.85 green:0.1 blue:0.1 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.45 green:0.0 blue:0.0 alpha:1.0].CGColor,
        (id)[UIColor blackColor].CGColor,
    ];
    gradient.locations = @[@0.0, @0.35, @1.0];
    [self.view.layer insertSublayer:gradient atIndex:0];

    // 脉冲光圈动画
    CALayer *pulseLayer = [CALayer layer];
    pulseLayer.frame = CGRectMake(0, 0, 160, 160);
    pulseLayer.position = CGPointMake(self.view.center.x, self.view.center.y - 100);
    pulseLayer.cornerRadius = 80;
    pulseLayer.backgroundColor = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:0.25].CGColor;
    [self.view.layer insertSublayer:pulseLayer above:gradient];

    CABasicAnimation *pulseAnim = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    pulseAnim.fromValue = @1.0;
    pulseAnim.toValue = @2.8;
    pulseAnim.duration = 1.8;
    pulseAnim.repeatCount = HUGE_VALF;
    pulseAnim.autoreverses = YES;
    [pulseLayer addAnimation:pulseAnim forKey:@"pulse"];

    // Container
    UIView *container = [[UIView alloc] initWithFrame:self.view.bounds];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:container];

    double mag = [self.eventData[@"magnitude"] doubleValue];
    double depth = [self.eventData[@"depth"] doubleValue];
    NSTimeInterval evTime = [self.eventData[@"time"] doubleValue];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:evTime];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";

    // 标题
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"⚠️ 地震预警 ⚠️";
    titleLabel.font = [UIFont boldSystemFontOfSize:22];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:titleLabel];

    // 震级大数字
    _magnitudeLabel = [[UILabel alloc] init];
    _magnitudeLabel.text = [NSString stringWithFormat:@"M %.1f", mag];
    _magnitudeLabel.font = [UIFont boldSystemFontOfSize:80];
    _magnitudeLabel.textColor = [UIColor whiteColor];
    _magnitudeLabel.textAlignment = NSTextAlignmentCenter;
    _magnitudeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_magnitudeLabel];

    // 震级等级
    NSString *lvlText = [self levelTextForMagnitude:mag];
    UIColor *lvlColor = [self levelColorForMagnitude:mag];
    UILabel *lvlLabel = [[UILabel alloc] init];
    lvlLabel.text = lvlText;
    lvlLabel.font = [UIFont boldSystemFontOfSize:15];
    lvlLabel.textColor = lvlColor;
    lvlLabel.textAlignment = NSTextAlignmentCenter;
    lvlLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    lvlLabel.layer.cornerRadius = 6;
    lvlLabel.clipsToBounds = YES;
    lvlLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:lvlLabel];

    // 位置
    UILabel *locLabel = [[UILabel alloc] init];
    locLabel.text = [NSString stringWithFormat:@"📍 %@", self.eventData[@"place"] ?: @"未知"];
    locLabel.font = [UIFont systemFontOfSize:17];
    locLabel.textColor = [UIColor whiteColor];
    locLabel.textAlignment = NSTextAlignmentCenter;
    locLabel.numberOfLines = 2;
    locLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:locLabel];

    // 详情
    UILabel *detailLabel = [[UILabel alloc] init];
    detailLabel.text = [NSString stringWithFormat:@"深度 %.1f km    ⏱ %@", depth, [fmt stringFromDate:date]];
    detailLabel.font = [UIFont systemFontOfSize:14];
    detailLabel.textColor = [UIColor colorWithWhite:0.9 alpha:0.9];
    detailLabel.textAlignment = NSTextAlignmentCenter;
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:detailLabel];

    // 数据源
    UILabel *sourceLabel = [[UILabel alloc] init];
    sourceLabel.text = [NSString stringWithFormat:@"数据源: %@", self.eventData[@"source"] ?: @"-"];
    sourceLabel.font = [UIFont systemFontOfSize:11];
    sourceLabel.textColor = [UIColor colorWithWhite:0.7 alpha:0.6];
    sourceLabel.textAlignment = NSTextAlignmentCenter;
    sourceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:sourceLabel];

    // 强度条
    UIView *barBg = [[UIView alloc] init];
    barBg.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.5];
    barBg.layer.cornerRadius = 6;
    barBg.clipsToBounds = YES;
    barBg.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:barBg];

    CGFloat intensity = MIN(mag / 9.0, 1.0);
    UIView *bar = [[UIView alloc] init];
    bar.backgroundColor = [UIColor colorWithRed:intensity green:1.0-intensity blue:0 alpha:1.0];
    bar.layer.cornerRadius = 6;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [barBg addSubview:bar];

    // 安全提示
    UILabel *tipLabel = [[UILabel alloc] init];
    tipLabel.text = [self safetyTipForMagnitude:mag];
    tipLabel.font = [UIFont systemFontOfSize:13];
    tipLabel.textColor = [UIColor colorWithRed:1 green:0.85 blue:0 alpha:0.9];
    tipLabel.textAlignment = NSTextAlignmentCenter;
    tipLabel.numberOfLines = 0;
    tipLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:tipLabel];

    // 关闭按钮
    _dismissButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_dismissButton setTitle:@"我知道了" forState:UIControlStateNormal];
    _dismissButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [_dismissButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _dismissButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    _dismissButton.layer.cornerRadius = 22;
    _dismissButton.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
    _dismissButton.layer.borderWidth = 1;
    _dismissButton.clipsToBounds = YES;
    _dismissButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_dismissButton addTarget:self action:@selector(dismissAlert) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:_dismissButton];

    // Auto Layout
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:25],
        [titleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [_magnitudeLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:15],
        [_magnitudeLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [lvlLabel.topAnchor constraintEqualToAnchor:_magnitudeLabel.bottomAnchor constant:6],
        [lvlLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [lvlLabel.widthAnchor constraintGreaterThanOrEqualToConstant:90],
        [lvlLabel.heightAnchor constraintEqualToConstant:28],

        [locLabel.topAnchor constraintEqualToAnchor:lvlLabel.bottomAnchor constant:18],
        [locLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [locLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [locLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],

        [detailLabel.topAnchor constraintEqualToAnchor:locLabel.bottomAnchor constant:10],
        [detailLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [barBg.topAnchor constraintEqualToAnchor:detailLabel.bottomAnchor constant:22],
        [barBg.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [barBg.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.65],
        [barBg.heightAnchor constraintEqualToConstant:12],

        [bar.topAnchor constraintEqualToAnchor:barBg.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:barBg.leadingAnchor],
        [bar.widthAnchor constraintEqualToAnchor:barBg.widthAnchor multiplier:intensity],
        [bar.heightAnchor constraintEqualToAnchor:barBg.heightAnchor],

        [sourceLabel.topAnchor constraintEqualToAnchor:barBg.bottomAnchor constant:4],
        [sourceLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [tipLabel.topAnchor constraintEqualToAnchor:sourceLabel.bottomAnchor constant:14],
        [tipLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [tipLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:30],
        [tipLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-30],

        [_dismissButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-50],
        [_dismissButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_dismissButton.widthAnchor constraintEqualToConstant:170],
        [_dismissButton.heightAnchor constraintEqualToConstant:44],
    ]];
}

// ============================================================
// 等级/提示
// ============================================================
- (NSString *)levelTextForMagnitude:(double)mag {
    if (mag < 3.0) return @"微震 · 注意";
    if (mag < 4.5) return @"有感地震 · 警惕";
    if (mag < 6.0) return @"中强震 · 危险";
    if (mag < 7.0) return @"强震 · 严重危险";
    if (mag < 8.0) return @"大地震 · 非常危险";
    return @"特大地震 · 极度危险";
}

- (UIColor *)levelColorForMagnitude:(double)mag {
    if (mag < 3.0) return [UIColor systemYellowColor];
    if (mag < 4.5) return [UIColor systemOrangeColor];
    if (mag < 6.0) return [UIColor systemRedColor];
    return [UIColor colorWithRed:1 green:0.2 blue:0.3 alpha:1];
}

- (NSString *)safetyTipForMagnitude:(double)mag {
    if (mag < 3.0) return @"注意安全，无需惊慌";
    if (mag < 4.5) return @"保持冷静，注意头顶物品";
    if (mag < 6.0) return @"请躲避到安全角落，远离窗户和重物";
    if (mag < 7.0) return @"紧急避险！躲在结实的桌子下，护住头部";
    return @"⚠️ 严重危险！立即寻找掩体，保护头部！不要乘坐电梯！";
}

// ============================================================
// 显示警报
// ============================================================
- (void)showAlert {
    [self playAlertSound];

    self.view.alpha = 0;
    [UIView animateWithDuration:0.35 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self.view.alpha = 1.0;
    } completion:nil];

    _magnitudeLabel.transform = CGAffineTransformMakeScale(0.3, 0.3);
    [UIView animateWithDuration:0.6 delay:0.15 usingSpringWithDamping:0.5 initialSpringVelocity:0.8 options:0 animations:^{
        self->_magnitudeLabel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

// ============================================================
// 警报音
// ============================================================
- (void)playAlertSound {
    if (_soundID == 0) {
        NSArray *paths = @[
            @"/var/jb/Library/Application Support/com.shuangye.earthquake/alert.caf",
            @"/Library/Application Support/com.shuangye.earthquake/alert.caf",
        ];
        for (NSString *path in paths) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                AudioServicesCreateSystemSoundID((__bridge CFURLRef)[NSURL fileURLWithPath:path], &_soundID);
                break;
            }
        }
    }

    AudioServicesPlayAlertSoundWithCompletion(_soundID ?: kSystemSoundID_Vibrate, ^{
        if (!self->_isDismissing) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ [self playAlertSound]; });
        }
    });
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

// ============================================================
// 关闭
// ============================================================
- (void)dismissAlert {
    if (_isDismissing) return;
    _isDismissing = YES;

    if (_soundID) {
        AudioServicesDisposeSystemSoundID(_soundID);
        _soundID = 0;
    }

    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.view.alpha = 0;
        self.view.transform = CGAffineTransformMakeScale(1.15, 1.15);
    } completion:^(BOOL f) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }];
}

@end

// ============================================================
// 警报管理器
// ============================================================
@interface EQAlertManager : NSObject
+ (instancetype)sharedManager;
- (void)handleEarthquakeAlert:(NSDictionary *)eventData;
@end

@implementation EQAlertManager {
    BOOL _alertShowing;
    NSString *_lastEventId;
}

+ (instancetype)sharedManager {
    static EQAlertManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)handleEarthquakeAlert:(NSDictionary *)eventData {
    if (_alertShowing) {
        NSLog(@"[EQAlert] 已显示警报，忽略重复");
        return;
    }
    NSString *eid = eventData[@"eventId"];
    if (eid && [_lastEventId isEqualToString:eid]) return;
    _lastEventId = eid;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWin = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:UIWindowScene.class] &&
                    ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
                    UIWindowScene *ws = (UIWindowScene *)scene;
                    keyWin = ws.keyWindow;
                    if (!keyWin) keyWin = ws.windows.firstObject;
                    break;
                }
            }
        }
        UIViewController *topVC = keyWin.rootViewController;
        while (topVC.presentedViewController) topVC = topVC.presentedViewController;
        if (!topVC) return;

        EQAlertViewController *vc = [[EQAlertViewController alloc] init];
        vc.eventData = eventData;
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

        self->_alertShowing = YES;
        [topVC presentViewController:vc animated:NO completion:^{ [vc showAlert]; }];
    });
}

@end

// ============================================================
// Darwin 通知回调
// ============================================================
static void EQNotificationCallback(CFNotificationCenterRef center,
                                    void *observer,
                                    CFStringRef name,
                                    const void *object,
                                    CFDictionaryRef userInfo) {
    NSDictionary *eventData = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.shuangye.earthquake.latest.plist"];
    if (!eventData) return;

    BOOL enabled = [EQPrefs boolForKey:@"enabled" defaultValue:YES];
    if (!enabled) return;

    double minMag = [EQPrefs doubleForKey:@"minMagnitude" defaultValue:2.5];
    if ([eventData[@"magnitude"] doubleValue] < minMag) return;

    NSLog(@"[EarthquakeAlert] 收到地震警报: M%@ %@", eventData[@"magnitude"], eventData[@"place"]);
    [[EQAlertManager sharedManager] handleEarthquakeAlert:eventData];
}

// ============================================================
// Hook: SpringBoard 初始化时注册监听
// ============================================================
%hook UIApplication

- (void)_run {
    %orig;

    NSLog(@"[EarthquakeAlert] 注册地震警报 Darwin 监听...");

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        EQNotificationCallback,
        CFSTR("com.shuangye.earthquake.alert"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    // 延时检查未读警报（等待 SB 完全加载）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.shuangye.earthquake.latest.plist"];
        if (d && [[NSDate date] timeIntervalSince1970] - [d[@"timestamp"] doubleValue] < 600) {
            NSLog(@"[EarthquakeAlert] 发现未读地震警报");
            [[EQAlertManager sharedManager] handleEarthquakeAlert:d];
        }
    });
}

%end
