#import "SneakyCamCCModule.h"
@implementation SneakyCamCCVideo { SneakyCamCCViewController *_vc; }
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController { if(!_vc)_vc=(id)SneakyCamCCCreateViewController(SneakyCamCCModeVideo);return _vc; }
- (UIViewController *)backgroundViewController{return nil;}
@end
