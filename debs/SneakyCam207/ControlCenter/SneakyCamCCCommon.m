#import "SneakyCamCCCommon.h"
#import "../SCPaths.h"
#import <notify.h>

#ifndef SC_CC_VC_CLASS
#define SC_CC_VC_CLASS SneakyCamCCFallbackViewController
#endif

@interface SC_CC_VC_CLASS : UIViewController <CCUIContentModuleContentViewController>
- (instancetype)initWithMode:(SneakyCamCCMode)mode;
- (void)refreshState;
@end

@interface SC_CC_VC_CLASS ()
@property(nonatomic,assign) SneakyCamCCMode mode;
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) UIImageView *glyphView;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *stateLabel;
@end

@implementation SC_CC_VC_CLASS
- (instancetype)initWithMode:(SneakyCamCCMode)mode { if((self=[super init])) _mode=mode; return self; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.clearColor; self.view.clipsToBounds=NO;
    _button=[UIButton buttonWithType:UIButtonTypeCustom]; _button.frame=self.view.bounds; _button.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; _button.backgroundColor=UIColor.clearColor; [_button addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside]; [self.view addSubview:_button];
    _glyphView=[UIImageView new]; _glyphView.contentMode=UIViewContentModeScaleAspectFit; [_button addSubview:_glyphView];
    _titleLabel=[UILabel new]; _titleLabel.textAlignment=NSTextAlignmentCenter; _titleLabel.adjustsFontSizeToFitWidth=YES; _titleLabel.minimumScaleFactor=.62; _titleLabel.numberOfLines=1; [_button addSubview:_titleLabel];
    _stateLabel=[UILabel new]; _stateLabel.textAlignment=NSTextAlignmentCenter; _stateLabel.adjustsFontSizeToFitWidth=YES; _stateLabel.minimumScaleFactor=.68; _stateLabel.numberOfLines=1; [_button addSubview:_stateLabel];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),(__bridge const void*)self,SCStateChanged,CFSTR("com.spark.SneakyCam.recordingstatechanged"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),(__bridge const void*)self,SCStateChanged,CFSTR("com.spark.SneakyCam.enabledchanged"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
    [self refreshState];
}
static void SCStateChanged(CFNotificationCenterRef c,void *o,CFStringRef n,const void *obj,CFDictionaryRef u){ SC_CC_VC_CLASS *v=(__bridge id)o; dispatch_async(dispatch_get_main_queue(),^{[v refreshState];}); }
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self refreshState]; [self.view setNeedsLayout]; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews]; CGFloat w=CGRectGetWidth(self.view.bounds),h=CGRectGetHeight(self.view.bounds); _button.frame=self.view.bounds;
    BOOL compact=(w<150&&h<150); CGFloat icon=compact?25:40,titleH=compact?15:25,stateH=compact?13:19,gap=compact?2:7,total=icon+gap+titleH+stateH,y=floor(MAX(compact?5:10,(h-total)/2)),inset=compact?3:18;
    _glyphView.frame=CGRectIntegral(CGRectMake((w-icon)/2,y,icon,icon)); y+=icon+gap; _titleLabel.frame=CGRectIntegral(CGRectMake(inset,y,MAX(0,w-inset*2),titleH)); y+=titleH; _stateLabel.frame=CGRectIntegral(CGRectMake(inset,y,MAX(0,w-inset*2),stateH));
    _titleLabel.font=[UIFont systemFontOfSize:compact?10:16 weight:UIFontWeightSemibold]; _stateLabel.font=[UIFont systemFontOfSize:compact?8:12 weight:UIFontWeightRegular];
}
- (BOOL)enabled { id v=SCReadPreferences()[@"Enabled"]; return v?[v boolValue]:NO; }
- (void)tapped:(id)sender {
    NSDictionary *p=SCReadPreferences();
    if(_mode==SneakyCamCCModeToggle){ BOOL e=![self enabled]; SCWritePreference(@"Enabled",@(e)); notify_post("com.spark.SneakyCam.enabledchanged"); notify_post("com.spark.SneakyCam"); }
    else if([self enabled] && _mode==SneakyCamCCModePhoto && [p[@"PhotoEnabled"]?:@YES boolValue]) notify_post("com.spark.SneakyCam.takephoto");
    else if([self enabled] && _mode==SneakyCamCCModeVideo && [p[@"VideoEnabled"]?:@YES boolValue]) notify_post("com.spark.SneakyCam.startstopvideo");
    // 总开关本身不提供震动；拍照/录像由实际执行成功路径统一反馈，避免叠加。
    [self refreshState];
}
- (void)refreshState {
    BOOL enabled=[self enabled],recording=[SCReadPreferences()[@"Recording"] boolValue]; NSString *symbol,*title,*state;
    if(_mode==SneakyCamCCModeToggle){symbol=@"camera.fill";title=@"記錄存檔";state=enabled?@"已开启":@"已关闭";}
    else if(_mode==SneakyCamCCModePhoto){symbol=@"camera.fill";title=@"記錄时刻";state=enabled?@"点击拍照":@"总开关关闭";}
    else {symbol=recording?@"video.fill":@"video";title=@"記錄生活";state=!enabled?@"总开关关闭":(recording?@"录制中":@"已停止");}
    _glyphView.image=[UIImage systemImageNamed:symbol]; _titleLabel.text=title; _stateLabel.text=state;
    CGFloat alpha=enabled?1:.72; _glyphView.tintColor=[UIColor colorWithWhite:1 alpha:alpha]; _titleLabel.textColor=[UIColor colorWithWhite:1 alpha:alpha]; _stateLabel.textColor=[UIColor colorWithWhite:1 alpha:enabled?.65:.5]; [self.view setNeedsLayout];
}
- (BOOL)shouldBeginTransitionToExpandedContentModule{return YES;}
- (void)willTransitionToExpandedContentMode:(BOOL)a{[self refreshState];[self.view setNeedsLayout];}
- (void)willReturnToExpandedContentModule{[self refreshState];[self.view setNeedsLayout];}
- (CGFloat)preferredExpandedContentHeight{return 180;}
- (CGFloat)preferredExpandedContentWidth{return MIN(MAX(CGRectGetWidth(UIScreen.mainScreen.bounds)-48,240),340);}
- (BOOL)providesOwnPlatter{return NO;}
- (void)dealloc { CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),(__bridge const void*)self,NULL,NULL); }
@end

UIViewController<CCUIContentModuleContentViewController> *SneakyCamCCCreateViewController(SneakyCamCCMode mode) {
    return [[SC_CC_VC_CLASS alloc] initWithMode:mode];
}
