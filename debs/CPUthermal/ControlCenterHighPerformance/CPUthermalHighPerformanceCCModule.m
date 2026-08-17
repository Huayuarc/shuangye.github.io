#import "CPUthermalHighPerformanceCCModule.h"

@implementation CPUthermalHighPerformanceCCModule {
    CPUthermalHighPerformanceCCModuleViewController *_contentViewController;
}
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    if (!_contentViewController) _contentViewController = [CPUthermalHighPerformanceCCModuleViewController new];
    return _contentViewController;
}
- (UIViewController *)backgroundViewController { return nil; }
@end
