#import "SneakyCamCCCommon.h"
#import "../SCPaths.h"
#import <notify.h>
#ifndef SC_CC_VC_CLASS
#define SC_CC_VC_CLASS SneakyCamCCFallbackViewController
#endif
@interface SC_CC_VC_CLASS : UIViewController <CCUIContentModuleContentViewController>
- (instancetype)initWithMode:(SneakyCamCCMode)mode; - (void)refreshState;
@end
@interface SC_CC_VC_CLASS ()
@property(nonatomic,assign) SneakyCamCCMode mode;@property(nonatomic,strong) UIButton *button;@property(nonatomic,strong) UIImageView *glyphView;
@end
@implementation SC_CC_VC_CLASS
- (instancetype)initWithMode:(SneakyCamCCMode)mode{if((self=[super init]))_mode=mode;return self;}
static void SCStateChanged(CFNotificationCenterRef c,void *o,CFStringRef n,const void *obj,CFDictionaryRef u){SC_CC_VC_CLASS *v=(__bridge id)o;dispatch_async(dispatch_get_main_queue(),^{[v refreshState];});}
- (void)viewDidLoad{[super viewDidLoad];self.view.backgroundColor=UIColor.clearColor;_button=[UIButton buttonWithType:UIButtonTypeCustom];_button.frame=self.view.bounds;_button.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;_button.layer.cornerRadius=18;_button.clipsToBounds=YES;[_button addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:_button];_glyphView=[UIImageView new];_glyphView.contentMode=UIViewContentModeScaleAspectFit;[_button addSubview:_glyphView];CFNotificationCenterRef dc=CFNotificationCenterGetDarwinNotifyCenter();CFNotificationCenterAddObserver(dc,(__bridge const void*)self,SCStateChanged,CFSTR("com.spark.SneakyCam.recordingstatechanged"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);CFNotificationCenterAddObserver(dc,(__bridge const void*)self,SCStateChanged,CFSTR("com.spark.SneakyCam.enabledchanged"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);[self refreshState];}
- (void)viewWillAppear:(BOOL)a{[super viewWillAppear:a];[self refreshState];}
- (void)controlCenterWillPresent{[self refreshState];}
- (void)viewDidLayoutSubviews{[super viewDidLayoutSubviews];_button.frame=self.view.bounds;CGFloat w=CGRectGetWidth(self.view.bounds),h=CGRectGetHeight(self.view.bounds);BOOL compact=w<150&&h<150;CGFloat icon=compact?48:68;_glyphView.frame=CGRectIntegral(CGRectMake((w-icon)/2,(h-icon)/2,icon,icon));_button.layer.cornerRadius=compact?18:24;}
- (BOOL)enabled{id v=SCReadPreferences()[@"Enabled"];return v?[v boolValue]:NO;}
- (void)tapped:(id)sender{NSDictionary *p=SCReadPreferences();if(_mode==SneakyCamCCModeToggle){BOOL e=![self enabled];SCWritePreference(@"Enabled",@(e));notify_post("com.spark.SneakyCam.enabledchanged");notify_post("com.spark.SneakyCam");}else if([self enabled]&&_mode==SneakyCamCCModePhoto&&[p[@"PhotoEnabled"]?:@YES boolValue])notify_post("com.spark.SneakyCam.takephoto");else if([self enabled]&&_mode==SneakyCamCCModeVideo&&[p[@"VideoEnabled"]?:@YES boolValue])notify_post("com.spark.SneakyCam.startstopvideo");[self refreshState];}
- (void)refreshState{NSDictionary *p=SCReadPreferences();BOOL total=[self enabled],recording=[p[@"Recording"] boolValue],active=NO;NSString *symbol=nil;UIColor *color=nil;if(_mode==SneakyCamCCModeToggle){active=total;symbol=@"camera.fill";color=[UIColor systemOrangeColor];}else if(_mode==SneakyCamCCModePhoto){active=total&&[p[@"PhotoEnabled"]?:@YES boolValue];symbol=@"camera.fill";color=[UIColor systemBlueColor];}else{active=total&&[p[@"VideoEnabled"]?:@YES boolValue];symbol=recording?@"video.fill":@"video";color=recording?[UIColor systemRedColor]:[UIColor systemPurpleColor];}_glyphView.image=[UIImage systemImageNamed:symbol];_button.backgroundColor=active?UIColor.whiteColor:[UIColor colorWithWhite:.35 alpha:.78];_glyphView.tintColor=active?color:[UIColor colorWithWhite:.82 alpha:.82];[self.view setNeedsLayout];}
- (BOOL)shouldBeginTransitionToExpandedContentModule{return YES;}- (void)willTransitionToExpandedContentMode:(BOOL)a{[self refreshState];}- (void)willReturnToExpandedContentModule{[self refreshState];}- (CGFloat)preferredExpandedContentHeight{return 180;}- (CGFloat)preferredExpandedContentWidth{return MIN(MAX(CGRectGetWidth(UIScreen.mainScreen.bounds)-48,240),340);}- (BOOL)providesOwnPlatter{return YES;}
- (void)dealloc{CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),(__bridge const void*)self,NULL,NULL);}
@end
UIViewController<CCUIContentModuleContentViewController>*SneakyCamCCCreateViewController(SneakyCamCCMode mode){return[[SC_CC_VC_CLASS alloc]initWithMode:mode];}
