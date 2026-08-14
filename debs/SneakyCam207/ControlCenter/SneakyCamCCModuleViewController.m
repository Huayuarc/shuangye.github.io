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
    self.view.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    self.view.layer.cornerRadius = 18; self.view.clipsToBounds = YES;
    _button = [UIButton buttonWithType:UIButtonTypeCustom]; _button.frame = self.view.bounds; _button.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; [_button addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside]; [self.view addSubview:_button];
    _glyphView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"camera.fill"]]; _glyphView.contentMode = UIViewContentModeScaleAspectFit; [_button addSubview:_glyphView];
    _titleLabel = [UILabel new]; _titleLabel.text = @"隐私相机"; _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]; _titleLabel.textAlignment = NSTextAlignmentCenter; [_button addSubview:_titleLabel];
    _stateLabel = [UILabel new]; _stateLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular]; _stateLabel.textAlignment = NSTextAlignmentCenter; [_button addSubview:_stateLabel];
    [self refreshState];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refreshState]; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; CGFloat w=CGRectGetWidth(self.view.bounds); _glyphView.frame=CGRectMake((w-30)/2,12,30,30); _titleLabel.frame=CGRectMake(4,45,w-8,18); _stateLabel.frame=CGRectMake(4,63,w-8,15); }
- (BOOL)isEnabled { id v=SCReadPreferences()[@"Enabled"]; return v ? [v boolValue] : NO; }
- (void)toggle:(id)sender { BOOL enabled=![self isEnabled]; SCWritePreference(@"Enabled",@(enabled)); notify_post("com.spark.SneakyCam.enabledchanged"); notify_post("com.spark.SneakyCam"); [self refreshState]; }
- (void)refreshState { BOOL enabled=[self isEnabled]; UIColor *c=enabled?[UIColor systemGreenColor]:[UIColor whiteColor]; _glyphView.tintColor=c; _titleLabel.textColor=c; _stateLabel.textColor=[UIColor colorWithWhite:1 alpha:0.65]; _stateLabel.text=enabled?@"已启用":@"已关闭"; self.view.backgroundColor=enabled?[UIColor colorWithRed:0.10 green:0.55 blue:0.25 alpha:0.82]:[UIColor colorWithWhite:1 alpha:0.12]; }
- (CGFloat)preferredExpandedContentHeight { return 100; }
- (CGFloat)preferredExpandedContentWidth { return 100; }
- (BOOL)providesOwnPlatter { return NO; }
@end
