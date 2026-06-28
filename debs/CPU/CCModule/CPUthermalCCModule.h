#import <Foundation/Foundation.h>
#import "CCUIHeaders.h"

NS_ASSUME_NONNULL_BEGIN

/// CPUthermal 控制中心模块
/// 实现 CCUIContentModule 协议，提供控制中心面板
@interface CPUthermalCCModule : NSObject <CCUIContentModule>

/// 内容视图控制器
@property (nonatomic, strong, readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;

/// 背景视图控制器
@property (nonatomic, strong, readonly) UIViewController *backgroundViewController;

@end

NS_ASSUME_NONNULL_END
