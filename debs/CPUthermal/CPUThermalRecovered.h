#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CTRThermalMode) {
    CTRThermalModeSystem = 0,       // 完全交还系统
    CTRThermalModePerformance = 1,  // 配置改写 + 压力抑制，不伪造温度
    CTRThermalModeAggressive = 2    // 额外假温度、跳过决策树、固定控制输入
};

typedef CTRThermalMode (*CTRThermalModeProvider)(void);

/// 由宿主插件提供实时模式回调；回调应轻量、线程安全。
FOUNDATION_EXPORT void CTRSetThermalModeProvider(CTRThermalModeProvider _Nullable provider);
/// 无回调时使用的模式。
FOUNDATION_EXPORT void CTRSetFallbackThermalMode(CTRThermalMode mode);
/// 安装已恢复且存在于当前系统的 Hook；可重复调用。
FOUNDATION_EXPORT void CTRInstallRecoveredThermalHooks(void);
/// 单独测试配置转换，不依赖 Hook。
FOUNDATION_EXPORT id _Nullable CTRTransformThermalConfiguration(id _Nullable configuration,
                                                                 CTRThermalMode mode);

NS_ASSUME_NONNULL_END
