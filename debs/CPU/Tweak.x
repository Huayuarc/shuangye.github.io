#import "CPUthermalHelper.h"
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>

// notify.h 通知名（与 CPUthermalPrefs.m 同步）
#define kCPUthermalReloadNotifyName  "com.huayuarc.cputhermal.reloadPrefs"

// ============================================================
// 动态查找 CommonProduct 实例（当 weak/strong 引用丢失时备用）
// ============================================================
// 供 LowPowerHooks.x 引用的 CommonProduct 实例
__attribute__((visibility("default"))) CommonProduct *g_lp_commonProduct = nil;

static CommonProduct *CPUthermalFindCommonProduct(void) {
    // CommonProduct 在 thermalmonitord 中是单例，用 objc_getClass 尝试查找
    Class cpClass = objc_getClass("CommonProduct");
    if (!cpClass) return nil;

    // 通过尝试调用可能存在的 shared 方法
    SEL sharedSel = @selector(sharedInstance);
    if ([cpClass respondsToSelector:sharedSel]) {
        id instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, sharedSel);
        if (instance) return instance;
    }
    sharedSel = @selector(sharedProduct);
    if ([cpClass respondsToSelector:sharedSel]) {
        id instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, sharedSel);
        if (instance) return instance;
    }

    return nil;
}

// ============================================================
// 同步 g_lp_commonProduct（供 LowPowerHooks.x 使用）
// ============================================================
static void CPUthermalSyncCommonProduct(void) {
    if (g_lp_commonProduct) return; // 已有引用
    CommonProduct *cp = CPUthermalFindCommonProduct();
    if (cp) {
        CPUthermalHelper.shared.commonProductObject = cp;
        g_lp_commonProduct = cp;
        NSLog(@"[CPUthermal] 动态获取 CommonProduct: %@", cp);
    }
}

// ============================================================
// 根据当前偏好设置 thermalmonitord 的工作模式
// ============================================================
static void CPUthermalApplyMode(void) {
    CPUthermalHelper *helper = CPUthermalHelper.shared;
    [helper reloadPrefs];

    // 尝试同步 CommonProduct 引用
    CPUthermalSyncCommonProduct();

    if (!helper.commonProductObject) {
        NSLog(@"[CPUthermal] commonProductObject 为空，尝试通过 LowPowerHooks 机制降频");
        // 即使 CommonProduct 不可用，也通过通知触发 LowPowerHooks 的备用机制
        goto fallback;
    }

    if ([helper.thermalPowerMode isEqualToString:@"lowPower"]) {
        // 低功耗：模拟中度热压力，触发系统主动降频
        [helper.commonProductObject putDeviceInThermalSimulationMode:@"moderate"];
        NSLog(@"[CPUthermal] 模式: 低功耗 (moderate)");
    } else {
        // 解除温控：恢复 Apple 原生温控策略
        [helper.commonProductObject putDeviceInThermalSimulationMode:@"nominal"];
        NSLog(@"[CPUthermal] 模式: 解除温控 (nominal)");
    }

    // 强制触发 CommonProduct 重新评估
    if ([helper.commonProductObject respondsToSelector:@selector(tryTakeAction)]) {
        [helper.commonProductObject tryTakeAction];
    }

    // 额外触发 handleMCSThermalPressure 确保热压力被处理
    if ([helper.commonProductObject respondsToSelector:@selector(handleMCSThermalPressure)]) {
        [helper.commonProductObject handleMCSThermalPressure];
    }

    return;

fallback:
    // 回退：通过 notify_post 触发 LowPowerHooks 的 notify handler
    notify_post(kCPUthermalReloadNotifyName);
    NSLog(@"[CPUthermal] 已发送回退通知给 LowPowerHooks");
}

// ============================================================
// CommonProduct - 初始化时注入helper并应用模式
// ============================================================

%hook CommonProduct

- (id)initProduct:(id)arg1 {
    id res = %orig(arg1);
    [CPUthermalHelper.shared setCommonProductObject:self];
    g_lp_commonProduct = self;
    CPUthermalApplyMode();
    return res;
}

%end

// ============================================================
// NSDictionary - 修补温控配置文件（防温控暗屏）
// ============================================================
%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
    id res = %orig(path);
    if ([path containsString:@"/System/Library/ThermalMonitor/"]) {
        if ([res isKindOfClass:[NSDictionary class]]) {
            CFDictionaryRef patched = [CPUthermalHelper.shared patchThermalPlist:(__bridge CFDictionaryRef)res];
            return (__bridge id)patched;
        }
    }
    return res;
}

%end

// ============================================================
// Darwin notification callback for puppet event
// ============================================================
static void puppetEventCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [CPUthermalHelper.shared executePuppetEvent];
}

// ============================================================
// Darwin notification callback for preference reload
// ============================================================
static void reloadPrefsCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    CPUthermalApplyMode();
}

%ctor {
    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();

    CFNotificationCenterAddObserver(
        nc,
        NULL,
        puppetEventCallback,
        CFSTR("com.huayuarc.cputhermal-executePuppetEvent"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // 监听偏好重载通知（如 CPU 模式切换）
    CFNotificationCenterAddObserver(
        nc,
        NULL,
        reloadPrefsCallback,
        CFSTR("com.huayuarc.cputhermal-reloadPrefs"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // 备用通道: notify.h 通知
    int token;
    notify_register_dispatch(kCPUthermalReloadNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
        CPUthermalApplyMode();
    });
}
