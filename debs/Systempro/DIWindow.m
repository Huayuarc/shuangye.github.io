#import "DIWindow.h"
#import "DIContentView.h"

@interface DIWindow ()
@property (nonatomic, strong) UIViewController *rootVC;
@property (nonatomic, strong, readwrite) DIContentView *contentView;
@end

@implementation DIWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelStatusBar + 100;
        self.backgroundColor = [UIColor clearColor];
        self.hidden = YES;
        self.userInteractionEnabled = YES;

        _rootVC = [[UIViewController alloc] init];
        _rootVC.view.backgroundColor = [UIColor clearColor];
        _rootVC.view.userInteractionEnabled = NO;
        self.rootViewController = _rootVC;

        // 监听屏幕旋转，重新布局 contentView
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(orientationChanged:)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];

        _contentView = [[DIContentView alloc] init];
        [_rootVC.view addSubview:_contentView];
    }
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.contentView.state == DIStateHidden || self.contentView.alpha < 0.1) {
        return nil;
    }
    CGPoint localPoint = [self.contentView convertPoint:point fromView:self];
    if ([self.contentView pointInside:localPoint withEvent:event]) {
        return [self.contentView hitTest:localPoint withEvent:event];
    }
    return nil;
}

- (void)show {
    if (!self.hidden) return;
    self.frame = [UIScreen mainScreen].bounds;
    self.hidden = NO;
    self.rootVC.view.userInteractionEnabled = YES;
}

- (void)hide {
    self.hidden = YES;
    self.rootVC.view.userInteractionEnabled = NO;
}

- (void)orientationChanged:(NSNotification *)note {
    if (self.hidden) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.frame = [UIScreen mainScreen].bounds;
        // 重新居中 contentView
        if (self.contentView.state != DIStateHidden) {
            CGFloat screenW = self.bounds.size.width;
            CGRect f = self.contentView.frame;
            f.origin.x = (screenW - f.size.width) / 2;
            self.contentView.transform = CGAffineTransformIdentity;
            self.contentView.frame = f;
        }
    });
}

@end
