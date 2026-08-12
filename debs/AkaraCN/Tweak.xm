#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>

static NSString *const AKRPrefs = @"com.huayuarc.akaracn";
static UIWindow *AKRWindow;
static BOOL AKRTransitioning = NO;
static NSMutableArray<UIWindow *> *AKRTriggers;

static NSDictionary *Prefs(void) { return [[NSUserDefaults standardUserDefaults] persistentDomainForName:AKRPrefs] ?: @{}; }
static BOOL PBool(NSString *key, BOOL fallback) { id v=Prefs()[key]; return v ? [v boolValue] : fallback; }
static double PNum(NSString *key, double fallback) { id v=Prefs()[key]; return v ? [v doubleValue] : fallback; }

@interface AKRPanelController : UIViewController
@property(nonatomic,strong) UIVisualEffectView *panel;
@property(nonatomic,strong) UILabel *clockLabel;
@end

static UIButton *AKRButton(NSString *symbol, NSString *title, SEL action, id target) {
    UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor=[UIColor colorWithWhite:0.10 alpha:0.82];
    b.layer.cornerRadius=PNum(@"cornerRadius",18);
    b.tintColor=UIColor.whiteColor;
    UIImageSymbolConfiguration *cfg=[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    [b setTitle:[@"  " stringByAppendingString:title] forState:UIControlStateNormal];
    b.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    b.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeft;
    b.contentEdgeInsets=UIEdgeInsetsMake(0,14,0,8);
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

@implementation AKRPanelController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.clearColor;
    UIBlurEffectStyle style=PBool(@"darkBlur",YES)?UIBlurEffectStyleSystemChromeMaterialDark:UIBlurEffectStyleSystemMaterialLight;
    self.panel=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:style]];
    self.panel.layer.cornerRadius=PNum(@"cornerRadius",22); self.panel.clipsToBounds=YES;
    [self.view addSubview:self.panel];
    UIView *c=self.panel.contentView;
    NSArray *buttons=@[
      AKRButton(@"airplane",@"飞行模式",@selector(airplane),self), AKRButton(@"flashlight.on.fill",@"手电筒",@selector(torch),self),
      AKRButton(@"wifi",@"Wi‑Fi",@selector(openWiFi),self), AKRButton(@"antenna.radiowaves.left.and.right",@"蜂窝网络",@selector(openCellular),self),
      AKRButton(@"bolt.horizontal.circle",@"蓝牙",@selector(openBluetooth),self), AKRButton(@"lock.rotation",@"旋转锁定",@selector(rotation),self)
    ];
    for(UIButton *b in buttons)[c addSubview:b];
    MPVolumeView *volume=[MPVolumeView new]; volume.showsRouteButton=NO; [c addSubview:volume];
    UISlider *brightness=[UISlider new]; brightness.minimumValue=0.02; brightness.maximumValue=1; brightness.value=UIScreen.mainScreen.brightness; brightness.minimumTrackTintColor=UIColor.whiteColor; [brightness addTarget:self action:@selector(brightness:) forControlEvents:UIControlEventValueChanged]; [c addSubview:brightness];
    self.clockLabel=[UILabel new]; self.clockLabel.textColor=UIColor.whiteColor; self.clockLabel.font=[UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold]; self.clockLabel.textAlignment=NSTextAlignmentCenter; [c addSubview:self.clockLabel];
    UIButton *close=AKRButton(@"chevron.down",@"关闭",@selector(close),self); [c addSubview:close];
    for(UIView *v in c.subviews)v.translatesAutoresizingMaskIntoConstraints=NO;
    UIButton *b0=buttons[0],*b1=buttons[1],*b2=buttons[2],*b3=buttons[3],*b4=buttons[4],*b5=buttons[5];
    NSDictionary *views=@{@"a":b0,@"b":b1,@"c":b2,@"d":b3,@"e":b4,@"f":b5,@"v":volume,@"r":brightness,@"t":self.clockLabel,@"x":close};
    [c addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[a]-8-[b(==a)]-12-|" options:0 metrics:nil views:views]];
    [c addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[c]-8-[d(==c)]-12-|" options:0 metrics:nil views:views]];
    [c addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[e]-8-[f(==e)]-12-|" options:0 metrics:nil views:views]];
    [c addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-18-[r]-18-|" options:0 metrics:nil views:views]];
    [c addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-18-[v]-18-|" options:0 metrics:nil views:views]];
    [c addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-12-[t]-8-[x(110)]-12-|" options:0 metrics:nil views:views]];
    [c addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-12-[a(58)]-8-[c(58)]-8-[e(58)]-12-[r(30)]-6-[v(30)]-12-[t(48)]-12-|" options:0 metrics:nil views:views]];
    for(UIButton *b in @[b1,b3,b5]) { [b.heightAnchor constraintEqualToConstant:58].active=YES; [b.centerYAnchor constraintEqualToAnchor:((UIButton *)buttons[[buttons indexOfObject:b]-1]).centerYAnchor].active=YES; }
    [close.heightAnchor constraintEqualToConstant:48].active=YES; [close.centerYAnchor constraintEqualToAnchor:self.clockLabel.centerYAnchor].active=YES;
    UISwipeGestureRecognizer *down=[[UISwipeGestureRecognizer alloc]initWithTarget:self action:@selector(close)]; down.direction=UISwipeGestureRecognizerDirectionDown; [self.view addGestureRecognizer:down];
    [self updateClock];
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; CGFloat w=MIN(self.view.bounds.size.width-32,PNum(@"panelWidth",360)); CGFloat h=430; self.panel.frame=CGRectMake((self.view.bounds.size.width-w)/2,self.view.bounds.size.height-h-28,w,h); }
- (void)updateClock { NSDateFormatter *f=[NSDateFormatter new]; f.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"]; f.dateFormat=@"M月d日 EEEE  HH:mm"; self.clockLabel.text=[f stringFromDate:NSDate.date]; }
- (void)brightness:(UISlider *)s { UIScreen.mainScreen.brightness=s.value; }
- (void)openWiFi { [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"App-Prefs:root=WIFI"] options:@{} completionHandler:nil]; }
- (void)openBluetooth { [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"App-Prefs:root=Bluetooth"] options:@{} completionHandler:nil]; }
- (void)openCellular { [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"App-Prefs:root=MOBILE_DATA_SETTINGS_ID"] options:@{} completionHandler:nil]; }
- (void)airplane { [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"App-Prefs:root=AIRPLANE_MODE"] options:@{} completionHandler:nil]; }
- (void)rotation { [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"App-Prefs:root=General"] options:@{} completionHandler:nil]; }
- (void)torch { AVCaptureDevice *d=[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo]; if(!d.hasTorch)return; [d lockForConfiguration:nil]; d.torchMode=d.torchActive?AVCaptureTorchModeOff:AVCaptureTorchModeOn; [d unlockForConfiguration]; }
- (void)close { extern void AKRHide(void); AKRHide(); }
@end

void AKRHide(void) {
    if(!AKRWindow||AKRTransitioning)return; AKRTransitioning=YES;
    [UIView animateWithDuration:.22 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{ AKRWindow.alpha=0; AKRWindow.transform=CGAffineTransformMakeTranslation(0,90); } completion:^(__unused BOOL done){ AKRWindow.hidden=YES; AKRWindow.rootViewController=nil; AKRWindow=nil; AKRTransitioning=NO; }];
}
static void AKRShow(void) {
    if(AKRWindow||AKRTransitioning||!PBool(@"enabled",YES))return; AKRTransitioning=YES;
    UIWindowScene *scene=nil; for(UIScene *s in UIApplication.sharedApplication.connectedScenes)if(s.activationState==UISceneActivationStateForegroundActive&&[s isKindOfClass:UIWindowScene.class]){scene=(UIWindowScene*)s;break;} if(!scene){AKRTransitioning=NO;return;}
    AKRWindow=[[UIWindow alloc]initWithWindowScene:scene]; AKRWindow.windowLevel=UIWindowLevelAlert+30; AKRWindow.backgroundColor=UIColor.clearColor; AKRWindow.rootViewController=[AKRPanelController new]; AKRWindow.alpha=0; AKRWindow.transform=CGAffineTransformMakeTranslation(0,90); AKRWindow.hidden=NO;
    [UIView animateWithDuration:.28 delay:0 usingSpringWithDamping:.86 initialSpringVelocity:.4 options:0 animations:^{ AKRWindow.alpha=1; AKRWindow.transform=CGAffineTransformIdentity; } completion:^(__unused BOOL done){AKRTransitioning=NO;}];
}
@interface AKRTriggerController:UIViewController @end
@implementation AKRTriggerController
- (void)loadView { self.view=[UIView new]; self.view.backgroundColor=UIColor.clearColor; UISwipeGestureRecognizer *g=[[UISwipeGestureRecognizer alloc]initWithTarget:self action:@selector(up)]; g.direction=UISwipeGestureRecognizerDirectionUp; [self.view addGestureRecognizer:g]; }
- (void)up { AKRShow(); }
@end
static void AKRInstallTriggers(void) {
    AKRTriggers=[NSMutableArray array];
    for(UIScene *s in UIApplication.sharedApplication.connectedScenes){if(![s isKindOfClass:UIWindowScene.class])continue; UIWindowScene *scene=(UIWindowScene*)s; CGFloat w=scene.screen.bounds.size.width; for(NSNumber *x in @[@0,@(w-72)]){UIWindow *t=[[UIWindow alloc]initWithWindowScene:scene]; t.frame=CGRectMake(x.doubleValue,scene.screen.bounds.size.height-38,72,38); t.windowLevel=UIWindowLevelStatusBar+2; t.backgroundColor=UIColor.clearColor; t.rootViewController=[AKRTriggerController new]; t.hidden=NO; [AKRTriggers addObject:t];}}
}
%ctor { if(![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"])return; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{AKRInstallTriggers();}); }
