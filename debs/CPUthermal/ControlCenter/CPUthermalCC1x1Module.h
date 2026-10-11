#import <Foundation/Foundation.h>
#import "CCUIHeaders.h"

NS_ASSUME_NONNULL_BEGIN

/// CPUthermal 控制中心 1×1 模块
/// 紧凑方形模块：显示当前运行方式（图标 + 文字），点按在 低功耗 / 解除温控 之间切换。
@interface CPUthermalCC1x1Module : NSObject <CCUIContentModule>

@property (nonatomic, strong, readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;

@end

NS_ASSUME_NONNULL_END
