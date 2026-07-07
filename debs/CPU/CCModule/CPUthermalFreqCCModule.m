#import "CPUthermalFreqCCModule.h"
#import "CPUthermalFreqCCModuleViewController.h"

@implementation CPUthermalFreqCCModule

@synthesize contentViewController = _contentViewController;

- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    if (!_contentViewController) {
        _contentViewController = [[CPUthermalFreqCCModuleViewController alloc] init];
    }
    return _contentViewController;
}

- (UIViewController *)backgroundViewController {
    return nil;
}

@end
