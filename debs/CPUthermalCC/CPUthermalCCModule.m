//==============================================================================
// InsulationCCModule.m
//==============================================================================

#import "InsulationCCModule.h"
#import "InsulationCCModuleViewController.h"

@implementation InsulationCCModule

@synthesize contentViewController = _contentViewController;
@synthesize backgroundViewController = _backgroundViewController;

- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    if (!_contentViewController) {
        _contentViewController = [[InsulationCCModuleViewController alloc] init];
    }
    return _contentViewController;
}

- (nullable UIViewController *)backgroundViewController {
    return nil;
}

@end
