//
//  Tweak_PrefHook.xm
//  CPUthermalPrefHook
//
//  适配自 fuckThermal (逆向还原)
//  目标: com.apple.Preferences 中的 ThermalManager
//  Hook: getBatteryServiceSuggestion:
//  功能: 拦截系统散热/电池服务建议, 使用 CPUthermal 的偏好设置作为开关
//
//  编译: clang + -fobjc-arc -lsubstrate -framework Foundation -framework CoreFoundation
//

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <notify.h>
#import <CPUthermalPaths.h>
#import <objc/runtime.h>
#import <syslog.h>

// ============================================================
// CPUthermal 偏好设置路径 (与主 tweak 共享)
// 注意: 必须用 C 字符串，不能用 @"" 常量
// roothide 重映射 dylib 后会破坏 __cfstring 的内部指针
// 导致加载时直接 SIGBUS (EXC_BAD_ACCESS)
// ============================================================
// ============================================================
// 全局状态
// ============================================================
static BOOL gEnabled = NO;
static BOOL gHookInstalled = NO;
static CFStringRef gNotifCFName = NULL;
static IMP orig_getBatteryServiceSuggestion = nil;

static NSDictionary *readPrefsDictionary(void) {
    return CPUthermalReadPrefs();
}

// ============================================================
// 读取偏好设置
// 动态创建 NSString，避免使用编译期 ObjC 常量
// ============================================================
static void loadPrefs(void) {
    @autoreleasepool {
        NSDictionary *d = readPrefsDictionary();
        if (d) {
            id enabledVal = [d objectForKey:S("enabled")];
            id suppressVal = [d objectForKey:S("suppressThermalNotifications")];
            BOOL enabled = enabledVal ? [enabledVal boolValue] : NO;
            BOOL suppress = suppressVal ? [suppressVal boolValue] : YES;
            gEnabled = enabled && suppress;
        } else {
            gEnabled = NO;
        }
    }
}

// ============================================================
// Hook 函数: 替换 ThermalManager.getBatteryServiceSuggestion:
// ============================================================
//
// ThermalManager 是 iOS 热管理内部类
// 方法: - (id)getBatteryServiceSuggestion:(id)suggestion
// 功能: 返回电池服务建议（如"降低亮度"等散热提示）
//
// 开启 CPUthermal 时 → 返回 nil (屏蔽系统散热建议)
// 关闭时 → 调用原实现
//
static id new_getBatteryServiceSuggestion(id self, SEL _cmd, id suggestion) {
    if (gEnabled) {
        // CPUthermal 激活: 返回 nil 屏蔽系统散热干预建议
        syslog(LOG_NOTICE, "[CPUthermalPrefHook] block ThermalManager suggestion");
        return nil;
    }

    if (!orig_getBatteryServiceSuggestion) {
        return nil;
    }

    return ((id (*)(id, SEL, id))orig_getBatteryServiceSuggestion)(self, _cmd, suggestion);
}

// ============================================================
// Darwin 通知回调 — 设置变更时重新加载
// ============================================================
static void onSettingsChanged(CFNotificationCenterRef center,
                               void *observer,
                               CFStringRef name,
                               const void *object,
                               CFDictionaryRef userInfo) {
    loadPrefs();
    syslog(LOG_NOTICE, "[CPUthermalPrefHook] settings reloaded, enabled=%d", gEnabled);
}

// ============================================================
// 找到 ThermalManager 类并 hook
// ============================================================
static void hookThermalManager(void) {
    if (gHookInstalled) {
        return;
    }

    Class thermalManagerClass = objc_getClass("ThermalManager");
    if (!thermalManagerClass) {
        syslog(LOG_NOTICE, "[CPUthermalPrefHook] ThermalManager class not found");
        return;
    }

    SEL selector = NSSelectorFromString(S("getBatteryServiceSuggestion:"));
    Method method = class_getInstanceMethod(thermalManagerClass, selector);
    if (!method) {
        syslog(LOG_NOTICE, "[CPUthermalPrefHook] getBatteryServiceSuggestion: not found");
        return;
    }

    orig_getBatteryServiceSuggestion = method_getImplementation(method);
    if (orig_getBatteryServiceSuggestion == (IMP)new_getBatteryServiceSuggestion) {
        gHookInstalled = YES;
        return;
    }

    method_setImplementation(method, (IMP)new_getBatteryServiceSuggestion);
    gHookInstalled = YES;

    syslog(LOG_NOTICE, "[CPUthermalPrefHook] hooked ThermalManager.getBatteryServiceSuggestion:");
}

// ============================================================
// Bundle 加载通知回调 — 等 Preferences 加载完成再 hook
// ============================================================
static void onBundleDidLoad(CFNotificationCenterRef center,
                             void *observer,
                             CFStringRef name,
                             const void *object,
                             CFDictionaryRef userInfo) {
    NSBundle *bundle = (__bridge NSBundle *)object;
    if ([bundle.bundleIdentifier isEqualToString:S("com.apple.Preferences")]) {
        // Preferences 加载完成, hook ThermalManager
        hookThermalManager();
    }
}

// ============================================================
// %ctor — 构造器
// ============================================================
%ctor {
    @autoreleasepool {
        // 1. 读取当前偏好设置
        loadPrefs();
        if (!gNotifCFName) {
            gNotifCFName = CFStringCreateWithCString(kCFAllocatorDefault, kCPUthermalSettingsChangedNotifC, kCFStringEncodingUTF8);
        }

        // 2. 监听 bundle 加载事件 (等 Preferences.app 加载)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetLocalCenter(),
            NULL,
            onBundleDidLoad,
            (__bridge CFStringRef)NSBundleDidLoadNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        // 3. 监听 Darwin 通知 (设置页面修改后触发刷新)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            onSettingsChanged,
            gNotifCFName,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        // 4. 立即尝试 hook (如果 ThermalManager 已加载)
        hookThermalManager();

        syslog(LOG_NOTICE, "[CPUthermalPrefHook] loaded, enabled=%d", gEnabled);
    }
}
