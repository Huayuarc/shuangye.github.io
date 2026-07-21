#import "PowercuffManager.h"
#import <CPUthermalPaths.h>
#import <objc/message.h>
#import <stdarg.h>

extern BOOL CPUthermalDebugLoggingEnabled(void);

static void CPUthermalPowercuffLog(NSString *format, ...) {
    if (!CPUthermalDebugLoggingEnabled() || !format) return;
    va_list args;
    va_start(args, format);
    NSLogv(format, args);
    va_end(args);
}

// ============================================================
// 支持的级别（与 rpetrich 的 Powercuff 一致）
//   off       → 关闭
//   nominal   → 正常（无节流）
//   light     → 轻度节流（~轻微降频）
//   moderate  → 中度节流（~明显省电）← 推荐用于低功耗
//   heavy     → 重度节流（~大幅度降频）
// ============================================================

/// 偏好设置键名
static const char *kPowercuffEnabledKeyC = "powercuffEnabled";
static const char *kPowercuffLevelKeyC = "powercuffLevel";

/// 默认热模拟级别（低功耗模式下使用）
static const char *kDefaultPowercuffLevelC = "moderate";

#pragma mark - Public API

NSString *powercuffReadLevel(void) {
    NSDictionary *prefs = CPUthermalReadPrefs();
    if (!prefs) return nil;

    // powercuff 需要有总开关 + 对应级别
    BOOL enabled = [[prefs objectForKey:S(kPowercuffEnabledKeyC)] boolValue];
    if (!enabled) return nil;

    // powercuff 仅在低功耗模式下生效，防温控模式不使用
    // 避免热模拟影响防温控模式的高频率性能
    NSString *powerMode = [prefs objectForKey:S("powerMode")];
    if (![powerMode isEqualToString:S("lowPower")]) {
        return nil;
    }

    NSString *level = [prefs objectForKey:S(kPowercuffLevelKeyC)];
    if (![level isKindOfClass:[NSString class]] || level.length == 0) {
        level = S(kDefaultPowercuffLevelC);
    }

    // 验证合法级别
    NSArray *validLevels = @[S("light"), S("moderate"), S("heavy"), S("nominal")];
    if (![validLevels containsObject:level]) return nil;

    return level;
}

BOOL powercuffShouldApply(void) {
    // 外部引用 CPUthermal 的全局变量无法直接访问，
    // 单独读取偏好来判断
    NSString *level = powercuffReadLevel();
    return level != nil;
}

void powercuffApply(id commonProduct, NSString *level) {
    if (!commonProduct) {
        NSLog(@"[CPUthermal][Powercuff] commonProduct 为 nil，跳过");
        return;
    }
    if (![commonProduct respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) {
        NSLog(@"[CPUthermal][Powercuff] CommonProduct 不支持 putDeviceInThermalSimulationMode:");
        return;
    }

    if (!level || [level isEqualToString:S("off")]) {
        // 关闭热模拟 — 重置为 nominal
        level = S("nominal");
    }

    CPUthermalPowercuffLog(@"[CPUthermal][Powercuff] 应用热模拟级别: %@", level);
    ((void (*)(id, SEL, NSString *))objc_msgSend)(commonProduct, @selector(putDeviceInThermalSimulationMode:), level);
}
