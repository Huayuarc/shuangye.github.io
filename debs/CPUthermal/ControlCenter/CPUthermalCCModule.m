#import "CPUthermalCCModule.h"
#import "CPUthermalCCModuleViewController.h"

@implementation CPUthermalCCModule

@synthesize contentViewController = _contentViewController;

- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    if (!_contentViewController) {
        _contentViewController = [[CPUthermalCCModuleViewController alloc] init];
    }
    return _contentViewController;
}

- (UIViewController *)backgroundViewController {
    return nil;
}

// 系统原生 ControlCenter 模块生命周期入口；每次控制中心呈现前刷新实时模式。
- (void)controlCenterWillPresent {
    UIViewController *controller = self.contentViewController;
    if ([controller respondsToSelector:@selector(refreshState)]) {
        [(id)controller refreshState];
    }
}

@end
