#import "SneakyCamCCModule.h"
@implementation SneakyCamCCPhoto { UIViewController<CCUIContentModuleContentViewController> *_vc; }
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController { if(!_vc)_vc=(id)SneakyCamCCCreateViewController(SneakyCamCCModePhoto);return _vc; }
- (UIViewController *)backgroundViewController{return nil;}
@end
