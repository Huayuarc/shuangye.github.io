#import <Foundation/Foundation.h>
#import "../ControlCenter/CCUIHeaders.h"

@class CPUthermalHighPerformanceCCModuleViewController;

@interface CPUthermalHighPerformanceCCModule : NSObject <CCUIContentModule>
@property(nonatomic,strong,readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@property(nonatomic,strong,readonly) UIViewController *backgroundViewController;
@end

@interface CPUthermalHighPerformanceCCModuleViewController : UIViewController <CCUIContentModuleContentViewController>
@end
