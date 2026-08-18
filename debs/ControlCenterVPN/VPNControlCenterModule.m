#import "VPNControlCenterModule.h"

@implementation VPNControlCenterModule {
    VPNControlCenterModuleViewController *_contentViewController;
}

- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    if (!_contentViewController) _contentViewController = [VPNControlCenterModuleViewController new];
    return _contentViewController;
}
- (UIViewController *)backgroundViewController { return nil; }
@end
