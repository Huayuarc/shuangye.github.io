//==============================================================================
// InsulationCCModuleViewController.h
// 逆向来源: com.be-huge.insulation v0.1.36
//==============================================================================

#import <ControlCenterUIKit/ControlCenterUIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Insulation 控制中心面板视图控制器
/// 继承 CCUIMenuModuleViewController，显示电源模式切换菜单
@interface InsulationCCModuleViewController : CCUIMenuModuleViewController

/// 模式值数组 (@[@"off", @"lowPower", @"fullPower"])
@property (nonatomic, copy) NSArray<NSString *> *modeValues;

/// 模式标题数组 (@[@"苹果原生温控", @"模拟低电频率", @"防止温控降频"])
@property (nonatomic, copy) NSArray<NSString *> *modeTitles;

/// 模式副标题数组
@property (nonatomic, copy) NSArray<NSString *> *modeSubtitles;

/// 当前选中的模式索引
@property (nonatomic, assign) NSInteger selectedIndex;

@end

NS_ASSUME_NONNULL_END
