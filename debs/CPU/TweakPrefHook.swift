import Foundation
import ObjectiveC

// ============================================================
// CPUthermalPrefHook — Preferences 散热建议拦截
//
// 目标: com.apple.Preferences 中的 ThermalManager
// Hook: getBatteryServiceSuggestion:
// 功能: 拦截系统散热/电池服务建议, 使用 CPUthermal 的偏好设置作为开关
// ============================================================

// MARK: - 全局状态

private var gEnabled = false

// MARK: - 偏好设置读取

private func loadPrefs() {
    guard let d = CPUthermalSwiftReadPrefs() else { gEnabled = false; return }
    let enabled = (d["enabled"] as? NSNumber)?.boolValue ?? true
    let suppress = (d["suppressThermalNotifications"] as? NSNumber)?.boolValue ?? false
    gEnabled = enabled && suppress
}

// MARK: - Hook 函数

private var origGetBatteryServiceSuggestionIMP: IMP?

private let newGetBatteryServiceSuggestionBlock: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { self, suggestion in
    if gEnabled {
        NSLog("[CPUthermalPrefHook] block ThermalManager suggestion")
        return nil
    }
    guard let orig = origGetBatteryServiceSuggestionIMP else { return nil }
    typealias OrigFunc = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
    return unsafeBitCast(orig, to: OrigFunc.self)(self, NSSelectorFromString("getBatteryServiceSuggestion:"), suggestion)
}

// MARK: - 安装 Hook

private func hookThermalManager() {
    guard let cls = objc_getClass("ThermalManager") as? AnyClass else {
        NSLog("[CPUthermalPrefHook] ThermalManager class not found")
        return
    }
    let sel = NSSelectorFromString("getBatteryServiceSuggestion:")
    guard let method = class_getInstanceMethod(cls, sel) else {
        NSLog("[CPUthermalPrefHook] getBatteryServiceSuggestion: not found")
        return
    }
    let currentIMP = method_getImplementation(method)
    // 防止重复 hook
    if currentIMP == imp_implementationWithBlock(unsafeBitCast(newGetBatteryServiceSuggestionBlock, to: AnyObject.self)) {
        return
    }
    origGetBatteryServiceSuggestionIMP = currentIMP
    method_setImplementation(method, imp_implementationWithBlock(unsafeBitCast(newGetBatteryServiceSuggestionBlock, to: AnyObject.self)))
    NSLog("[CPUthermalPrefHook] hooked ThermalManager.getBatteryServiceSuggestion:")
}

// MARK: - 通知回调

private let onSettingsChanged: CFNotificationCallback = { _, _, _, _, _ in
    loadPrefs()
    NSLog("[CPUthermalPrefHook] settings reloaded, enabled=\(gEnabled)")
}

private let onBundleDidLoad: CFNotificationCallback = { _, _, name, object, _ in
    guard let bundle = object as? Bundle else { return }
    if bundle.bundleIdentifier == "com.apple.Preferences" {
        hookThermalManager()
    }
}

// MARK: - 初始化 (constructor)

private let _initialize: Void = {
    loadPrefs()

    // 监听 bundle 加载事件
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetLocalCenter(),
        nil, onBundleDidLoad,
        "NSBundleDidLoadNotification" as CFString, nil,
        .deliverImmediately
    )

    // 监听 Darwin 通知 (设置页面修改后触发刷新)
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        nil, onSettingsChanged,
        "com.huayuarc.CPUthermal/settingsChanged" as CFString, nil,
        .deliverImmediately
    )

    // 立即尝试 hook (如果 ThermalManager 已加载)
    hookThermalManager()

    NSLog("[CPUthermalPrefHook] loaded, enabled=\(gEnabled)")
}()
