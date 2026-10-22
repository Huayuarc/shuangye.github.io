#import "CCCompat.h"
#define VB_FRONTEND_IMPLEMENTATION
#import "../shared/Frontend.h"
#import "TouchGate.h"

@class VBModule;
@interface VBModuleViewController : UIViewController <CCUIContentModuleContentViewController>
@property(nonatomic, weak) VBModule *module;
@property(nonatomic) UIButton *button;
- (void)render;
- (void)showUserActions;
@end

@interface VBModule : NSObject <CCUIContentModule>
@property(nonatomic) VBModuleViewController *controller;
@property(nonatomic, getter=isSelected) BOOL selected;
- (void)handleUserTouchFromControl:(UIControl *)control event:(UIEvent *)event;
@end

@implementation VBModule
- (instancetype)init {
    if ((self = [super init])) {
        // Initializing or reloading a module never enables/disables anything.
        dispatch_async(dispatch_get_main_queue(), ^{ [VBFrontend.shared query]; });
    } return self;
}
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    if (!self.controller) {
        self.controller = [VBModuleViewController new]; self.controller.module = self;
    } return self.controller;
}
- (UIViewController *)backgroundViewController { return nil; }
- (BOOL)isSelected { return [VBFrontend.shared.result.state isEqual:@"enabled"]; }
- (void)setSelected:(BOOL)selected {
    // Intentionally ignore requested values: SpringBoard/CCSupport may invoke
    // this during reconstruction, refresh or layout. This is presentation ONLY.
    if (NSThread.isMainThread) [self.controller render];
    else dispatch_async(dispatch_get_main_queue(), ^{ [self.controller render]; });
}
- (void)refreshState {
    if (NSThread.isMainThread) [self.controller render];
    else dispatch_async(dispatch_get_main_queue(), ^{ [self.controller render]; });
}
- (void)handleUserTouchFromControl:(UIControl *)control event:(UIEvent *)event {
    if (!VBRealTouch(control, event) || VBFrontend.shared.busy) return;
    [self.controller showUserActions];
}
@end

@implementation VBModuleViewController
- (CGFloat)preferredExpandedContentHeight { return 180; }
- (CGFloat)preferredExpandedContentWidth { return 240; }
- (BOOL)providesOwnPlatter { return NO; }
- (BOOL)shouldBeginTransitionToExpandedContentModule { return NO; }
- (BOOL)canDismissPresentedContent { return self.presentedViewController == nil; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.button = [UIButton buttonWithType:UIButtonTypeCustom];
    self.button.translatesAutoresizingMaskIntoConstraints = NO;
    self.button.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.85];
    self.button.layer.cornerRadius = 16; self.button.clipsToBounds = YES;
    self.button.titleLabel.numberOfLines = 2;
    self.button.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.button.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    self.button.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.button.titleLabel.minimumScaleFactor = 0.7;
    [self.button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.button.accessibilityLabel = @"vnodebypass 状态和操作";
    [self.button addTarget:self action:@selector(buttonTapped:event:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.button];
    [NSLayoutConstraint activateConstraints:@[
        [self.button.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.button.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.button.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.button.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(render)
        name:VB_FRONTEND_UPDATED object:VBFrontend.shared];
    [self render];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [VBFrontend.shared query]; }
- (void)controlCenterWillPresent { [VBFrontend.shared query]; }
- (void)willBecomeActive { [VBFrontend.shared query]; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // A compact vertical arrangement without requiring newer UIButton APIs.
    CGFloat width = self.button.bounds.size.width;
    CGFloat height = self.button.bounds.size.height;
    CGFloat glyph = MIN(24, height * 0.40);
    self.button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.button.imageView.frame = CGRectMake((width - glyph) / 2, MAX(4, height * 0.14), glyph, glyph);
    self.button.titleLabel.frame = CGRectMake(2, height * 0.57, MAX(0, width - 4), height * 0.38);
}
- (void)render {
    if (!self.isViewLoaded) return;
    VBFrontend *f = VBFrontend.shared;
    BOOL enabled = [f.result.state isEqual:@"enabled"];
    NSString *state = f.busy ? @"读取/执行中" :
        (enabled ? @"已启用" : ([f.result.state isEqual:@"disabled"] ? @"已关闭" :
        ([f.result.state isEqual:@"mixed"] ? @"部分隐藏" :
        ([f.result.state isEqual:@"legacy"] ? @"旧版状态" :
        ([f.result.state isEqual:@"busy"] ? @"Helper 忙" : @"状态错误")))));
    [self.button setTitle:[@"vnodebypass\n" stringByAppendingString:state] forState:UIControlStateNormal];
    NSBundle *bundle = [NSBundle bundleForClass:VBModule.class];
    UIImage *icon = [UIImage imageNamed:enabled ? @"enabled" : @"disabled" inBundle:bundle compatibleWithTraitCollection:nil];
    if (!icon) icon = [UIImage systemImageNamed:enabled ? @"eye.slash" : @"eye"];
    [self.button setImage:[icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    self.button.tintColor = enabled ? UIColor.systemBlueColor : UIColor.whiteColor;
    self.button.accessibilityValue = [NSString stringWithFormat:@"%@，隐藏 %lu/%lu，%@", state,
        (unsigned long)f.result.hidden, (unsigned long)f.result.total, f.result.message];
    self.button.enabled = !f.busy; self.button.alpha = f.busy ? 0.5 : 1;
    [self.view setNeedsLayout];
}
- (void)buttonTapped:(UIButton *)sender event:(UIEvent *)event {
    // No event, no write-capable UI. Neither setSelected: nor init can reach it.
    [self.module handleUserTouchFromControl:sender event:event];
}
- (void)showUserActions {
    if (self.presentedViewController || !self.view.window || VBFrontend.shared.busy) return;
    VBResult *r = VBFrontend.shared.result;
    NSString *detail = [NSString stringWithFormat:@"%@\n隐藏 %lu / %lu\n%@\n%@",
        VBStateTitle(r.state), (unsigned long)r.hidden, (unsigned long)r.total,
        r.message, VBFrontend.shared.lastOperationMessage];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"vnodebypass"
        message:detail preferredStyle:UIAlertControllerStyleAlert];
    if ([r.state isEqual:@"disabled"] && r.success) {
        alert.message = [detail stringByAppendingFormat:@"\n\n%@", VBEnableWarning()];
        [alert addAction:[UIAlertAction actionWithTitle:@"确认启用隐藏" style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *action) { [VBFrontend.shared performCommand:@"enable"]; }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"显式关闭隐藏" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) { [VBFrontend.shared performCommand:@"disable"]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"仅刷新状态" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) { [VBFrontend.shared query]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
