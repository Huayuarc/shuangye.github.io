#import "CPUthermalCC1x1Module.h"
#import "CPUthermalCC1x1ModuleViewController.h"

@implementation CPUthermalCC1x1Module

@synthesize contentViewController = _contentViewController;

- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    if (!_contentViewController) {
        _contentViewController = [[CPUthermalCC1x1ModuleViewController alloc] init];
    }
    return _contentViewController;
}

@end
