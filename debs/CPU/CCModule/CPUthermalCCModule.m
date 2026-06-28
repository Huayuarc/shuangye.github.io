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

@end
