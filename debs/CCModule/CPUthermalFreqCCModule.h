#import <Foundation/Foundation.h>
#import "CCUIHeaders.h"

NS_ASSUME_NONNULL_BEGIN

@interface CPUthermalFreqCCModule : NSObject <CCUIContentModule>
@property (nonatomic, strong, readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@property (nonatomic, strong, readonly) UIViewController *backgroundViewController;
@end

NS_ASSUME_NONNULL_END
