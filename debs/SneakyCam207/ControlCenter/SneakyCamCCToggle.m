#import "SneakyCamCCModule.h"
@implementation SneakyCamCCToggle { SneakyCamCCViewController *_vc; }
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController { if(!_vc)_vc=(id)SneakyCamCCCreateViewController(SneakyCamCCModeToggle);return _vc; }
- (UIViewController *)backgroundViewController{return nil;}
@end
