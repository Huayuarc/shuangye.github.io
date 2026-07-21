#ifndef POWERCUFF_MANAGER_H
#define POWERCUFF_MANAGER_H

#import <Foundation/Foundation.h>

// ============================================================
// PowercuffManager — rpetrich's Powercuff 原生移植
// 通过 CommonProduct 的 putDeviceInThermalSimulationMode:
// 在 thermalmonitord 进程中维持 CPU 热模拟状态。
//
// 集成到 CPUthermal:
//   - loadPrefs() 中调用 readPowercuffPrefs() 加载配置
//   - 低功耗模式启用时自动调用 applyThermalSimulation()
//   - 2秒连续定时器中周期性重应用
//   - %hook CommonProduct 中拦截系统复位调用
// ============================================================

/// 从 CPUthermal 偏好设置中读取 powercuff 配置
/// @return 热模拟级别字符串 (@"light"/@"moderate"/@"heavy")，关闭时返回 nil
NSString *powercuffReadLevel(void);

/// 实时判断当前是否应该启用热模拟
BOOL powercuffShouldApply(void);

/// 通过 CommonProduct 应用热模拟级别
/// @param commonProduct CommonProduct 实例（从 g_commonProduct 传入）
/// @param level 热模拟级别，nil 或 @"off" 表示关闭
void powercuffApply(id commonProduct, NSString *level);

#endif
