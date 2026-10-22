#import <UIKit/UIKit.h>
#define VB_FRONTEND_IMPLEMENTATION
#import "../shared/Frontend.h"
#import "TouchGate.h"

@interface VBRootViewController : UIViewController
@property(nonatomic) UILabel *stateLabel;
@property(nonatomic) UILabel *detailLabel;
@property(nonatomic) UILabel *operationLabel;
@property(nonatomic) UIButton *enableButton;
@property(nonatomic) UIButton *disableButton;
@property(nonatomic) UIButton *refreshButton;
@property(nonatomic) UIActivityIndicatorView *spinner;
@end

@implementation VBRootViewController
- (UILabel *)label:(NSString *)text size:(CGFloat)size {
    UILabel *label = [UILabel new]; label.text = text;
    label.font = [UIFont systemFontOfSize:size]; label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter; label.numberOfLines = 0; return label;
}
- (UIButton *)button:(NSString *)title selector:(SEL)selector color:(UIColor *)color {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    button.backgroundColor = color; button.layer.cornerRadius = 12;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UILabel *title = [self label:@"vnodebypass" size:40];
    UILabel *warning = [self label:@"USE IT AT YOUR OWN RISK!" size:18];
    warning.textColor = UIColor.systemOrangeColor;
    self.stateLabel = [self label:@"正在读取状态…" size:24];
    self.stateLabel.accessibilityTraits = UIAccessibilityTraitUpdatesFrequently;
    self.detailLabel = [self label:@"" size:15];
    self.detailLabel.textColor = UIColor.lightGrayColor;
    self.operationLabel = [self label:@"" size:14];
    self.operationLabel.textColor = UIColor.systemOrangeColor;
    self.enableButton = [self button:@"显式启用隐藏" selector:@selector(enableTapped:event:)
                              color:UIColor.systemBlueColor];
    self.disableButton = [self button:@"显式关闭隐藏" selector:@selector(disableTapped:event:)
                               color:UIColor.darkGrayColor];
    self.refreshButton = [self button:@"仅刷新状态" selector:@selector(refreshTapped:event:)
                               color:[UIColor colorWithWhite:0.12 alpha:1]];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    UILabel *note = [self label:@"全局隐藏可能影响其他插件。\n回到前台只查询状态，不会自动启用或恢复。" size:14];
    note.textColor = UIColor.lightGrayColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, warning, self.stateLabel, self.detailLabel, self.operationLabel,
        self.spinner, self.enableButton, self.disableButton, self.refreshButton, note]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll]; [scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:30],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-30],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48]
    ]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(render)
        name:VB_FRONTEND_UPDATED object:VBFrontend.shared];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(becameActive)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [self render];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)becameActive { [VBFrontend.shared query]; }
- (void)render {
    VBFrontend *f = VBFrontend.shared; VBResult *r = f.result;
    self.stateLabel.text = [NSString stringWithFormat:@"%@%@", VBStateTitle(r.state), f.busy ? @"\n正在查询 / 执行…" : @""];
    self.detailLabel.text = [NSString stringWithFormat:@"隐藏 %lu / %lu\n%@", (unsigned long)r.hidden,
                             (unsigned long)r.total, r.message];
    self.operationLabel.text = f.lastOperationMessage;
    self.enableButton.enabled = !f.busy && [r.state isEqual:@"disabled"] && r.success;
    self.disableButton.enabled = !f.busy;
    self.refreshButton.enabled = !f.busy;
    for (UIButton *b in @[self.enableButton, self.disableButton, self.refreshButton])
        b.alpha = b.enabled ? 1 : 0.4;
    if (f.busy) [self.spinner startAnimating]; else [self.spinner stopAnimating];
}
- (void)enableTapped:(UIButton *)sender event:(UIEvent *)event {
    if (!VBRealTouch(sender, event) || VBFrontend.shared.busy || self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认全局隐藏"
        message:VBEnableWarning() preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确认启用" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) { [VBFrontend.shared performCommand:@"enable"]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)disableTapped:(UIButton *)sender event:(UIEvent *)event {
    if (VBRealTouch(sender, event)) [VBFrontend.shared performCommand:@"disable"];
}
- (void)refreshTapped:(UIButton *)sender event:(UIEvent *)event {
    if (VBRealTouch(sender, event)) [VBFrontend.shared query];
}
@end

@interface VBAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow *window;
@end
@implementation VBAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [VBRootViewController new];
    [self.window makeKeyAndVisible]; return YES;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(VBAppDelegate.class)); }
}
