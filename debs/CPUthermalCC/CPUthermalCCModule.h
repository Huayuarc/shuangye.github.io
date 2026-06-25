//==============================================================================
// InsulationCCModule.h - 控制中心模块
// 逆向来源: com.be-huge.insulation v0.1.36
//==============================================================================

#import <Foundation/Foundation.h>
#import <ControlCenterUIKit/ControlCenterUIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Insulation 控制中心模块
/// 实现 CCUIContentModule 协议，提供控制中心面板
@interface InsulationCCModule : NSObject <CCUIContentModule>

/// 内容视图控制器（InsulationCCModuleViewController 实例）
@property (nonatomic, strong, readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;

/// 背景视图控制器
@property (nonatomic, strong, readonly) UIViewController *backgroundViewController;

@end

NS_ASSUME_NONNULL_END
