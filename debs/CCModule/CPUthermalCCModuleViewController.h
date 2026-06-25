#import "CCUIHeaders.h"

NS_ASSUME_NONNULL_BEGIN

/// CPUthermal 控制中心面板视图控制器
/// 继承 CCUIMenuModuleViewController，显示功率模式切换菜单
@interface CPUthermalCCModuleViewController : CCUIMenuModuleViewController

/// 模式值数组 (@[@"lowPower", @"fullPower"])
@property (nonatomic, copy) NSArray<NSString *> *modeValues;

/// 模式标题数组 (@[@"低功耗", @"解除温控"])
@property (nonatomic, copy) NSArray<NSString *> *modeTitles;

/// 当前选中的模式索引
@property (nonatomic, assign) NSInteger selectedIndex;

/// 刷新状态（从 Prefs 重新读取）
- (void)refreshState;

@end

NS_ASSUME_NONNULL_END
