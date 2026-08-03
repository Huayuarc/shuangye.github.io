//
//  CPUthermalSCPrefs.h
//
//  移植自 Battman-1.0.3.3 scprefs/scprefs.h
//
//  背景：
//    iOS SDK 将 SystemConfiguration 的 SCPreferences* API 标记为
//    API_UNAVAILABLE(ios)（"not available on iOS"），直接 include 系统头会编译报错。
//    但这些符号在 iOS 的 SystemConfiguration.framework 中真实存在
//    （thermalmonitord / cfprefsd 等系统守护进程依赖它们）。
//
//  方案：
//    自定义声明所需的 SCPreferences 函数原型，绕过 SDK availability 检查，
//    与 Battman 的 scprefs.h 做法完全一致。HIP(口袋过热)模块依赖此头。
//
#ifndef CPUTHERMAL_SCPREFS_H
#define CPUTHERMAL_SCPREFS_H

#include <CoreFoundation/CoreFoundation.h>

// SCPreferences 状态码（与系统头枚举值一致）
enum {
    kSCStatusOK,            // 0: 成功
    kSCStatusFailed = 1001, // 失败
    kSCStatusStale  = 3005, // 过期
};

CF_IMPLICIT_BRIDGING_ENABLED
CF_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

typedef const struct CF_BRIDGED_TYPE(id) __SCPreferences *SCPreferencesRef;

// 创建 SCPreferences 句柄（name=调用者标识, prefsID=plist 文件名）
SCPreferencesRef __nullable SCPreferencesCreate(CFAllocatorRef __nullable allocator, CFStringRef name, CFStringRef __nullable prefsID);

// 读取偏好值
CFPropertyListRef __nullable SCPreferencesGetValue(SCPreferencesRef prefs, CFStringRef key);

// 写入偏好值
Boolean SCPreferencesSetValue(SCPreferencesRef prefs, CFStringRef key, CFPropertyListRef value);

// 删除偏好值
Boolean SCPreferencesRemoveValue(SCPreferencesRef prefs, CFStringRef key);

// 同步（不落盘）
void SCPreferencesSynchronize(SCPreferencesRef prefs);

// 应用修改（触发监听者回调）
Boolean SCPreferencesApplyChanges(SCPreferencesRef prefs);

// 提交修改（写入磁盘）
Boolean SCPreferencesCommitChanges(SCPreferencesRef prefs);

// 最近一次错误码
int SCError(void);

// 错误码转字符串
const char * SCErrorString(int status);

__END_DECLS

CF_ASSUME_NONNULL_END
CF_IMPLICIT_BRIDGING_DISABLED

#endif /* CPUTHERMAL_SCPREFS_H */
