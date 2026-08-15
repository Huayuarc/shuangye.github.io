#import <Foundation/Foundation.h>
#import "CCUIHeaders.h"

@interface SneakyCamCCModule : NSObject <CCUIContentModule>
@property(nonatomic,strong,readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@property(nonatomic,strong,readonly) UIViewController *backgroundViewController;
@end

@interface SneakyCamCCModuleViewController : UIViewController <CCUIContentModuleContentViewController>
- (void)refreshState;
@end
