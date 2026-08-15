#import "SneakyCamCCModule.h"
#import "../SCPaths.h"
#import <notify.h>

@interface SneakyCamCCModuleViewController ()
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) UIImageView *glyphView;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *stateLabel;
@end

@implementation SneakyCamCCModuleViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.clearColor;
    self.view.clipsToBounds=NO;
    _button=[UIButton buttonWithType:UIButtonTypeCustom];
    _button.frame=self.view.bounds;
    _button.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _button.backgroundColor=UIColor.clearColor;
    [_button addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_button];

    UIImageSymbolConfiguration *config=[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
    _glyphView=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"camera.fill" withConfiguration:config]];
    _glyphView.contentMode=UIViewContentModeScaleAspectFit;
    [_button addSubview:_glyphView];

    _titleLabel=[UILabel new];
    _titleLabel.text=@"隐私相机";
    _titleLabel.textAlignment=NSTextAlignmentCenter;
    _titleLabel.adjustsFontSizeToFitWidth=YES;
    _titleLabel.minimumScaleFactor=0.65;
    _titleLabel.numberOfLines=1;
    _titleLabel.lineBreakMode=NSLineBreakByClipping;
    [_button addSubview:_titleLabel];

    _stateLabel=[UILabel new];
    _stateLabel.textAlignment=NSTextAlignmentCenter;
    _stateLabel.adjustsFontSizeToFitWidth=YES;
    _stateLabel.minimumScaleFactor=0.70;
    _stateLabel.numberOfLines=1;
    _stateLabel.lineBreakMode=NSLineBreakByClipping;
    [_button addSubview:_stateLabel];
    [self refreshState];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated];[self refreshState];[self.view setNeedsLayout]; }
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated];[self.view setNeedsLayout]; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds=self.view.bounds;
    CGFloat w=CGRectGetWidth(bounds),h=CGRectGetHeight(bounds);
    _button.frame=bounds;
    BOOL compact=(w<150.0 && h<150.0);
    CGFloat icon=compact?24.0:38.0;
    CGFloat titleH=compact?15.0:24.0;
    CGFloat stateH=compact?12.0:19.0;
    CGFloat gap=compact?2.0:7.0;
    CGFloat total=icon+gap+titleH+stateH;
    CGFloat y=floor(MAX(compact?5.0:10.0,(h-total)/2.0));
    CGFloat inset=compact?3.0:18.0;
    _glyphView.frame=CGRectIntegral(CGRectMake((w-icon)/2.0,y,icon,icon));
    y+=icon+gap;
    _titleLabel.frame=CGRectIntegral(CGRectMake(inset,y,MAX(0,w-inset*2),titleH));
    y+=titleH;
    _stateLabel.frame=CGRectIntegral(CGRectMake(inset,y,MAX(0,w-inset*2),stateH));
    _titleLabel.font=[UIFont systemFontOfSize:compact?10.0:16.0 weight:UIFontWeightSemibold];
    _stateLabel.font=[UIFont systemFontOfSize:compact?8.0:12.0 weight:UIFontWeightRegular];
    [_titleLabel invalidateIntrinsicContentSize];
    [_stateLabel invalidateIntrinsicContentSize];
}
- (BOOL)isEnabled { id v=SCReadPreferences()[@"Enabled"];return v?[v boolValue]:NO; }
- (void)toggle:(id)sender { BOOL enabled=![self isEnabled];SCWritePreference(@"Enabled",@(enabled));notify_post("com.spark.SneakyCam.enabledchanged");notify_post("com.spark.SneakyCam");[self refreshState]; }
- (void)refreshState {
    BOOL enabled=[self isEnabled];
    _button.backgroundColor=UIColor.clearColor;
    _glyphView.tintColor=[UIColor colorWithWhite:1.0 alpha:enabled?1.0:0.78];
    _titleLabel.textColor=[UIColor colorWithWhite:1.0 alpha:enabled?1.0:0.84];
    _stateLabel.textColor=[UIColor colorWithWhite:1.0 alpha:enabled?0.72:0.58];
    _stateLabel.text=enabled?@"已启用":@"已关闭";
}
- (BOOL)shouldBeginTransitionToExpandedContentModule { return YES; }
- (void)willTransitionToExpandedContentMode:(BOOL)animated { [self refreshState];[self.view setNeedsLayout]; }
- (void)willReturnToExpandedContentModule { [self refreshState];[self.view setNeedsLayout]; }
- (CGFloat)preferredExpandedContentHeight { return 180.0; }
- (CGFloat)preferredExpandedContentWidth { CGFloat w=CGRectGetWidth(UIScreen.mainScreen.bounds)-48.0;return MIN(MAX(w,240.0),340.0); }
- (BOOL)providesOwnPlatter { return NO; }
@end
