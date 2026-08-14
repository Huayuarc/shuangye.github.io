#import "SneakyCamCCModule.h"

@implementation SneakyCamCCModule {
    SneakyCamCCModuleViewController *_contentViewController;
}
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    if (!_contentViewController) _contentViewController = [SneakyCamCCModuleViewController new];
    return _contentViewController;
}
- (UIViewController *)backgroundViewController { return nil; }
@end
