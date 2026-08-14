#import "SneakyCamCCModule.h"
#import "../SCPaths.h"
#import <notify.h>

@interface SneakyCamCCModuleViewController ()
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) UIImageView *glyphView;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *stateLabel;
@property(nonatomic,assign) BOOL expanded;
@end

@implementation SneakyCamCCModuleViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.clipsToBounds = YES;
    _button = [UIButton buttonWithType:UIButtonTypeCustom];
    _button.frame = self.view.bounds;
    _button.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _button.clipsToBounds = YES;
    [_button addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_button];

    UIImageSymbolConfiguration *config=[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
    _glyphView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"camera.fill" withConfiguration:config]];
    _glyphView.contentMode = UIViewContentModeScaleAspectFit;
    [_button addSubview:_glyphView];

    _titleLabel = [UILabel new];
    _titleLabel.text = @"隐私相机";
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.72;
    _titleLabel.numberOfLines = 1;
    [_button addSubview:_titleLabel];

    _stateLabel = [UILabel new];
    _stateLabel.textAlignment = NSTextAlignmentCenter;
    _stateLabel.adjustsFontSizeToFitWidth = YES;
    _stateLabel.minimumScaleFactor = 0.75;
    _stateLabel.numberOfLines = 1;
    [_button addSubview:_stateLabel];
    [self refreshState];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refreshState]; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w=CGRectGetWidth(self.view.bounds), h=CGRectGetHeight(self.view.bounds);
    BOOL roomy=_expanded || w>150.0 || h>150.0;
    _button.frame=self.view.bounds;
    _button.layer.cornerRadius=roomy?24.0:18.0;
    CGFloat icon=roomy?38.0:26.0;
    CGFloat titleH=roomy?24.0:16.0, stateH=roomy?19.0:13.0;
    CGFloat gap=roomy?7.0:3.0;
    CGFloat total=icon+gap+titleH+stateH;
    CGFloat y=MAX(8.0,(h-total)/2.0);
    _glyphView.frame=CGRectMake((w-icon)/2.0,y,icon,icon);
    y+=icon+gap;
    CGFloat inset=roomy?18.0:5.0;
    _titleLabel.frame=CGRectMake(inset,y,MAX(0,w-inset*2),titleH);
    y+=titleH;
    _stateLabel.frame=CGRectMake(inset,y,MAX(0,w-inset*2),stateH);
    _titleLabel.font=[UIFont systemFontOfSize:roomy?16.0:11.0 weight:UIFontWeightSemibold];
    _stateLabel.font=[UIFont systemFontOfSize:roomy?12.0:9.0 weight:UIFontWeightRegular];
}
- (BOOL)isEnabled { id v=SCReadPreferences()[@"Enabled"]; return v?[v boolValue]:NO; }
- (void)toggle:(id)sender { BOOL enabled=![self isEnabled];SCWritePreference(@"Enabled",@(enabled));notify_post("com.spark.SneakyCam.enabledchanged");notify_post("com.spark.SneakyCam");[self refreshState]; }
- (void)refreshState {
    BOOL enabled=[self isEnabled];
    _button.backgroundColor=enabled?[UIColor colorWithWhite:0.42 alpha:0.96]:[UIColor colorWithWhite:0.34 alpha:0.90];
    _glyphView.tintColor=[UIColor colorWithWhite:1.0 alpha:enabled?1.0:0.82];
    _titleLabel.textColor=[UIColor colorWithWhite:1.0 alpha:enabled?1.0:0.86];
    _stateLabel.textColor=[UIColor colorWithWhite:1.0 alpha:0.62];
    _stateLabel.text=enabled?@"已启用":@"已关闭";
}
- (BOOL)shouldBeginTransitionToExpandedContentModule { return YES; }
- (void)willTransitionToExpandedContentMode:(BOOL)animated { _expanded=YES;[self.view setNeedsLayout];[self refreshState]; }
- (void)willReturnToExpandedContentModule { _expanded=YES;[self.view setNeedsLayout]; }
- (CGFloat)preferredExpandedContentHeight { return 180.0; }
- (CGFloat)preferredExpandedContentWidth { CGFloat w=CGRectGetWidth(UIScreen.mainScreen.bounds)-48.0;return MIN(MAX(w,240.0),340.0); }
- (BOOL)providesOwnPlatter { return YES; }
@end
