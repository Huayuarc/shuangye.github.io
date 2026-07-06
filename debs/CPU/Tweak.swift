import Foundation

// ============================================================================
// CPUthermal — 温控插件（完全版 Swift 移植）
//
// 双防护层设计:
//   第1层 (IOKit): 拦截传感器温度读取、降频操作、属性写入、Darwin 通知广播
//   第2层 (ObjC):  钩住 thermalmonitord 内部类决策方法，阻止热缓解动作
//
// 安全阀: 超过 65°C 或读温失败时放行所有系统保护
// ============================================================================

private let KERN_SUCCESS: kern_return_t = 0
private let NOTIFY_STATUS_OK: UInt32 = 0
private let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
private let RTLD_NOW = Int32(2)

// MARK: - 配置与全局状态

private var g_enabled: Bool = true
private var g_cpuProtection: Bool = true
private var g_brightnessProtection: Bool = true
private var g_keepCPSMAlive: Bool = true
private var g_suppressThermalNotifications: Bool = false

private enum CPUthermalPowerMode: Int {
    case full = 0
    case low = 1
}

private var g_powerMode: CPUthermalPowerMode = .full

private let kLowPowerMinFrequencyMHz: Int64 = 600
private let kLowPowerMaxFrequencyMHz: Int64 = 2016
private let kSafetyTempThreshold: Int64 = 70000

private var g_commonProduct: AnyObject?
private var g_mitigationControllers = NSMutableArray()
private var g_restoringFullPower: Bool = false
private var g_applyingLowPower: Bool = false
private var g_originalControllerValues = NSMutableDictionary()
private var g_processStartTime: CFAbsoluteTime = 0
private let kFullPowerBootGuardDuration: Double = 5.0
private var g_deferredRuntimeApplyScheduled: Bool = false
private var g_fullPowerRecoveryPulseScheduled: Bool = false
private var g_lowPowerApplyPulseScheduled: Bool = false
private var g_wakeRuntimeApplyScheduled: Bool = false

// 温度缓存锁
private var g_tempCacheLock = os_unfair_lock()
private var g_cachedTemperature: Int64 = 0
private var g_cachedTemperatureTime: CFAbsoluteTime = 0
private let kTempCacheDuration: Double = 1.5

// MARK: - Connection 追踪

private let kMaxConn = 64
private struct ConnEntry {
    var conn: io_connect_t = 0
    var isThermal: Bool = false
}
private var g_conns = [ConnEntry](repeating: ConnEntry(), count: kMaxConn)
private var g_connCount: Int = 0

private func trackConnection(_ conn: io_connect_t, isThermal: Bool) {
    guard g_connCount < kMaxConn else { return }
    g_conns[g_connCount].conn = conn
    g_conns[g_connCount].isThermal = isThermal
    g_connCount += 1
}

private func isThermalConnection(_ conn: io_connect_t) -> Bool {
    for i in 0..<g_connCount {
        if g_conns[i].conn == conn { return g_conns[i].isThermal }
    }
    return false
}

private func serviceIsThermal(_ service: io_service_t) -> Bool {
    var nameBuffer = [CChar](repeating: 0, count: 128)
    guard IORegistryEntryGetName(service, &nameBuffer) == KERN_SUCCESS else { return false }
    let nameStr = String(cString: nameBuffer)
    let hotServices: [String] = ["AppleSPU", "AppleSPU.original", "AppleARMPlatform", "pmu", "ApplePMGR"]
    return hotServices.contains(nameStr)
}

// MARK: - 选择器范围判定

private func selectorIsTemp(_ s: UInt32) -> Bool { s >= 0x10 && s <= 0x1F }
private func selectorIsMitigation(_ s: UInt32) -> Bool { (s >= 0x40 && s <= 0x5F) || s == 0x30 || s == 0x31 }
private func selectorIsCritical(_ s: UInt32) -> Bool { s >= 0x60 && s <= 0x6F }

// MARK: - 偏好设置读取

private func readPrefsDictionary() -> NSDictionary? {
    CPUthermalSwiftReadPrefs()
}

private func loadPrefs() {
    guard let d = readPrefsDictionary() else { return }
    g_enabled = (d["enabled"] as? NSNumber)?.boolValue ?? true
    g_cpuProtection = (d["cpuProtection"] as? NSNumber)?.boolValue ?? true
    g_brightnessProtection = (d["brightnessProtection"] as? NSNumber)?.boolValue ?? true
    g_keepCPSMAlive = (d["keepCPMSAlive"] as? NSNumber)?.boolValue ?? true
    g_suppressThermalNotifications = (d["suppressThermalNotifications"] as? NSNumber)?.boolValue ?? false
    let mode = d["powerMode"] as? String ?? "fullPower"
    g_powerMode = mode == "lowPower" ? .low : .full
}

// MARK: - 辅助函数

private func controllerKey(_ controller: AnyObject, _ name: UnsafePointer<CChar>) -> String {
    "\(Unmanaged.passUnretained(controller).toOpaque()):\(String(cString: name))"
}

private func rememberOriginalIntValue(_ controller: AnyObject, _ name: UnsafePointer<CChar>, _ value: Int) {
    guard !g_restoringFullPower, !g_applyingLowPower, shouldApplyLowPowerLimit(), value > lowPowerTargetValue() else { return }
    let key = controllerKey(controller, name)
    guard g_originalControllerValues[key] == nil else { return }
    g_originalControllerValues[key] = value
}

private func rememberedOriginalIntValue(_ controller: AnyObject, _ name: UnsafePointer<CChar>, _ fallback: Int) -> Int {
    (g_originalControllerValues[controllerKey(controller, name)] as? Int) ?? fallback
}

private var isLowPowerMode: Bool { g_powerMode == .low }
private var isFullPowerMode: Bool { g_powerMode == .full }

private func fullPowerBootGuardActive() -> Bool {
    guard isFullPowerMode, g_processStartTime > 0 else { return false }
    return (CFAbsoluteTimeGetCurrent() - g_processStartTime) < kFullPowerBootGuardDuration
}

private func shouldApplyFullCPUProtection() -> Bool {
    g_enabled && g_cpuProtection && isFullPowerMode && !fullPowerBootGuardActive()
}

private func shouldApplyLowPowerLimit() -> Bool {
    g_enabled && g_cpuProtection && isLowPowerMode
}

private func lowPowerTargetValue() -> Int { Int(kLowPowerMaxFrequencyMHz) }
private func lowPowerPowerCeilingValue() -> Int { 40 }
private func lowPowerPowerFloorValue() -> Int { 0 }
private func fullPowerTargetValue() -> Int { 100 }
private func fullPowerFrequencyValue() -> Int { Int(CPUthermalSwiftNativeMaxPCoreFrequencyMHz()) }
private func fullPowerPercentValue() -> Int { 100 }

private var cpuMaxPowerPropertyName: CFString = {
    CFStringCreateWithCString(kCFAllocatorDefault, "CPUMaxPower", kCFStringEncodingUTF8)!
}()

private func methodEncodingContains(_ object: AnyObject, _ sel: Selector, _ needle: UnsafePointer<CChar>) -> Bool {
    guard let method = class_getInstanceMethod(type(of: object), sel),
          let types = method_getTypeEncoding(method) else { return false }
    return strstr(types, needle) != nil
}

private func methodArgumentIsObject(_ object: AnyObject, _ sel: Selector, _ index: UInt32) -> Bool {
    guard let method = class_getInstanceMethod(type(of: object), sel) else { return false }
    var type = [CChar](repeating: 0, count: 32)
    method_getArgumentType(method, index, &type, type.count)
    return type[0] == 64 // '@'
}

private func setMaxCPUPowerTargetUsesCFString(_ controller: AnyObject) -> Bool {
    methodEncodingContains(controller, NSSelectorFromString("setMaxCPUPowerTarget:useLegacyPath:setProperty:"), "^{__CFString=}")
}

private func setMaxCPUPowerPropertyArgument(_ controller: AnyObject) -> UnsafeMutableRawPointer {
    setMaxCPUPowerTargetUsesCFString(controller)
        ? Unmanaged.passUnretained(cpuMaxPowerPropertyName).toOpaque()
        : UnsafeMutableRawPointer(bitPattern: 1)!
}

private func normalizedPropertyArg(_ controller: AnyObject, _ property: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    if setMaxCPUPowerTargetUsesCFString(controller) && UInt(bitPattern: property) < 4096 {
        return Unmanaged.passUnretained(cpuMaxPowerPropertyName).toOpaque()
    }
    return property
}

private func intIvarValue(_ object: AnyObject, _ name: UnsafePointer<CChar>, _ fallback: Int) -> Int {
    var cls: AnyClass? = type(of: object)
    while let c = cls {
        if let ivar = class_getInstanceVariable(c, name) {
            let offset = ivar_getOffset(ivar)
            return UnsafeMutableRawPointer(Unmanaged.passUnretained(object).toOpaque())
                .advanced(by: offset)
                .assumingMemoryBound(to: Int32.self)
                .pointee
        }
        cls = class_getSuperclass(c)
    }
    return fallback
}

private func fullPowerTargetForController(_ controller: AnyObject) -> Int {
    let remembered = rememberedOriginalIntValue(controller, "MaxCPUPowerTarget", 0)
    if remembered > lowPowerTargetValue() { return remembered }
    let maxPower = intIvarValue(controller, "_maxCPUPower", 0)
    if maxPower > lowPowerTargetValue() { return maxPower }
    let realTarget = intIvarValue(controller, "_currentRealCPUPowerTarget", 0)
    if realTarget > lowPowerTargetValue() { return realTarget }
    return fullPowerFrequencyValue()
}

private func fullPowerCeilingForController(_ controller: AnyObject) -> Int {
    let remembered = rememberedOriginalIntValue(controller, "CPUPowerCeiling", fullPowerTargetValue())
    return remembered > lowPowerTargetValue() ? remembered : fullPowerTargetValue()
}

private func fullPowerFloorForController(_ controller: AnyObject) -> Int {
    rememberedOriginalIntValue(controller, "CPUPowerFloor", 0)
}

private func fullPowerZoneTargetForController(_ controller: AnyObject) -> Int {
    let remembered = rememberedOriginalIntValue(controller, "CPUPowerZoneTarget", 0)
    return remembered > lowPowerTargetValue() ? remembered : fullPowerTargetForController(controller)
}

// MARK: - 温度安全阀检查

private func readTemperatureFromService(_ serviceName: UnsafePointer<CChar>, _ propertyName: UnsafePointer<CChar>) -> Int64? {
    guard let matching = IOServiceNameMatching(serviceName) else { return nil }
    let service = IOServiceGetMatchingService(kIOMasterPortDefault, matching.takeRetainedValue())
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let key = CFStringCreateWithCString(kCFAllocatorDefault, propertyName, kCFStringEncodingUTF8) else { return nil }
    guard let temp = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
    guard CFGetTypeID(temp) == CFNumberGetTypeID() else { return nil }
    var val: Int64 = 0
    guard CFNumberGetValue(unsafeBitCast(temp, to: CFNumber.self), kCFNumberSInt64Type, &val) else { return nil }
    return val
}

private func isTemperatureAboveSafetyCeiling() -> Bool {
    guard g_keepCPSMAlive else { return false }
    let now = CFAbsoluteTimeGetCurrent()

    if g_cachedTemperatureTime > 0, (now - g_cachedTemperatureTime) < kTempCacheDuration {
        return g_cachedTemperature >= kSafetyTempThreshold
    }

    os_unfair_lock_lock(&g_tempCacheLock)

    if g_cachedTemperatureTime > 0, (now - g_cachedTemperatureTime) < kTempCacheDuration {
        let cached = g_cachedTemperature
        os_unfair_lock_unlock(&g_tempCacheLock)
        return cached >= kSafetyTempThreshold
    }

    var tempVal: Int64 = 0
    var readOK = false

    // 主路径: AppleARMPlatform
    if let t = readTemperatureFromService("AppleARMPlatform", "temperature") {
        tempVal = t; readOK = true
    }
    // Fallback 1: AppleSPU
    if !readOK, let t = readTemperatureFromService("AppleSPU", "temperature") {
        tempVal = t; readOK = true
    }
    // Fallback 2: pmu
    if !readOK, let t = readTemperatureFromService("pmu", "temperature") {
        tempVal = t; readOK = true
    }

    if readOK {
        g_cachedTemperature = tempVal
        g_cachedTemperatureTime = now
    } else {
        g_cachedTemperatureTime = 0
    }

    os_unfair_lock_unlock(&g_tempCacheLock)

    if !readOK { return true }
    return tempVal >= kSafetyTempThreshold
}

// MARK: - 低功耗频率辅助

private func frequencyMHzFromValue(_ value: Int64) -> Int64 {
    if value >= 1_000_000_000 { return value / 1_000_000 }
    if value >= 1_000_000 { return value / 1_000 }
    return value
}

private func frequencyValueFromMHz(_ mhz: Int64, _ originalValue: Int64) -> Int64 {
    if originalValue >= 1_000_000_000 { return mhz * 1_000_000 }
    if originalValue >= 1_000_000 { return mhz * 1_000 }
    return mhz
}

private func clampLowPowerFrequencyValue(_ value: Int64) -> Int64 {
    var mhz = frequencyMHzFromValue(value)
    if mhz < kLowPowerMinFrequencyMHz { mhz = kLowPowerMinFrequencyMHz }
    if mhz > kLowPowerMaxFrequencyMHz { mhz = kLowPowerMaxFrequencyMHz }
    return frequencyValueFromMHz(mhz, value)
}

private func keyMatchesLowPowerLimit(_ key: String) -> Bool {
    let lower = key.lowercased()
    let isCPUKey = lower.contains("cpu") || lower.contains("ppm") || lower.contains("processor")
    let isFrequencyKey = lower.contains("freq") || lower.contains("frequency")
    let isLowPowerTargetKey = (isCPUKey || lower.contains("package")) && lower.contains("lowpower") && lower.contains("target")
    let isMaxCPUPowerTargetKey = isCPUKey && lower.contains("max") && lower.contains("power") && lower.contains("target")
    let isPowerZoneTargetKey = isCPUKey && lower.contains("powerzone") && lower.contains("target")
    return (isCPUKey && isFrequencyKey) || isLowPowerTargetKey || isMaxCPUPowerTargetKey || isPowerZoneTargetKey
}

private func copyLowPowerFrequencyValueForKey(_ key: String, _ originalValue: CFTypeRef?) -> CFTypeRef? {
    guard keyMatchesLowPowerLimit(key) else { return nil }
    let lower = key.lowercased()
    let isMinKey = key.localizedCaseInsensitiveContains("min") || key.localizedCaseInsensitiveContains("floor")
    let isFrequencyKey = lower.contains("freq") || lower.contains("frequency")

    var original: Int64 = kLowPowerMaxFrequencyMHz
    if let val = originalValue, CFGetTypeID(val) == CFNumberGetTypeID() {
        CFNumberGetValue(unsafeBitCast(val, to: CFNumber.self), kCFNumberSInt64Type, &original)
    } else if isMinKey && isFrequencyKey {
        original = kLowPowerMinFrequencyMHz
    }

    let replacement = isMinKey && isFrequencyKey
        ? frequencyValueFromMHz(kLowPowerMinFrequencyMHz, original)
        : clampLowPowerFrequencyValue(original)
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &replacement)
}

private func lowPowerNumberForKey(_ key: String, _ originalNumber: NSNumber?) -> NSNumber? {
    guard keyMatchesLowPowerLimit(key) else { return nil }
    let lower = key.lowercased()
    let isMinKey = key.localizedCaseInsensitiveContains("min") || key.localizedCaseInsensitiveContains("floor")
    let isFrequencyKey = lower.contains("freq") || lower.contains("frequency")
    let original = originalNumber?.int64Value ?? kLowPowerMaxFrequencyMHz
    let replacement = isMinKey && isFrequencyKey
        ? frequencyValueFromMHz(kLowPowerMinFrequencyMHz, original)
        : clampLowPowerFrequencyValue(original)
    return NSNumber(value: replacement)
}

private func patchedLowPowerConfigObject(_ object: Any, _ keyHint: String?) -> Any? {
    if let num = object as? NSNumber {
        return lowPowerNumberForKey(keyHint ?? "", num) ?? object
    }
    if let array = object as? [Any] {
        return array.compactMap { patchedLowPowerConfigObject($0, keyHint) }
    }
    if let dict = object as? [AnyHashable: Any] {
        var result = dict
        for (k, v) in dict {
            let childKey: String
            if let sk = k as? String, let hint = keyHint {
                childKey = "\(hint).\(sk)"
            } else {
                childKey = keyHint ?? "\(k)"
            }
            if let patched = patchedLowPowerConfigObject(v, childKey) {
                result[k] = patched
            }
        }
        return result
    }
    return object
}

// MARK: - 热通知判定 & 亮度保护

private func isThermalNotificationName(_ name: String) -> Bool {
    let lower = name.lowercased()
    return lower.contains("thermalstate")
        || lower.contains("thermal-level")
        || lower.contains("osthermal")
        || lower.contains("kosthermalnotification")
        || (lower.contains("thermal") && (lower.contains("high") || lower.contains("pressure") || lower.contains("warning") || lower.contains("notification")))
}

private func shouldBlockBrightnessProperty(_ key: String, _ value: CFTypeRef?) -> Bool {
    let lower = key.lowercased()
    let isBrightnessKey = lower.contains("brightness") || lower.contains("backlight")
    guard isBrightnessKey else { return false }
    if lower.contains("displaystatus") || lower.contains("blank") || lower.contains("sleep") || lower.contains("wake") || lower.contains("powerstate") {
        return false
    }
    if let val = value, CFGetTypeID(val) == CFNumberGetTypeID() {
        var numeric: Double = 0
        if CFNumberGetValue(unsafeBitCast(val, to: CFNumber.self), kCFNumberDoubleType, &numeric), numeric <= 0.01 {
            return false
        }
    }
    return lower.contains("thermal") || lower.contains("mitigat") || lower.contains("throttle")
        || lower.contains("reduce") || lower.contains("limit") || lower.contains("target")
        || lower.contains("sunlight") || lower.contains("pressure") || lower.contains("hot")
}

// MARK: - 控制器管理

private func trackPowerController(_ controller: AnyObject) {
    guard !g_mitigationControllers.contains(controller) else { return }
    g_mitigationControllers.add(controller)
}

private func applyLowPowerLimitToController(_ controller: AnyObject) {
    guard shouldApplyLowPowerLimit() else { return }
    g_applyingLowPower = true
    defer { g_applyingLowPower = false }
    let setPowerSaveSel = NSSelectorFromString("setPowerSaveActive:")
    if controller.responds(to: setPowerSaveSel) {
        _ = controller.perform(setPowerSaveSel, with: true)
    }
    let setLowPowerTargetSel = NSSelectorFromString("setCPULowPowerTarget:")
    if controller.responds(to: setLowPowerTargetSel) {
        _ = controller.perform(setLowPowerTargetSel, with: lowPowerTargetValue())
    }
    let setMaxPowerSel = NSSelectorFromString("setMaxCPUPowerTarget:useLegacyPath:setProperty:")
    if controller.responds(to: setMaxPowerSel) {
        typealias SetMaxPowerFunc = @convention(c) (AnyObject, Selector, Int, Bool, UnsafeMutableRawPointer) -> Void
        let imp = class_getMethodImplementation(type(of: controller) as! AnyClass, setMaxPowerSel)
        let f = unsafeBitCast(imp, to: SetMaxPowerFunc.self)
        f(controller, setMaxPowerSel, lowPowerTargetValue(), false, setMaxCPUPowerPropertyArgument(controller))
    }

    NSLog("CPUthermal 已主动下发低功耗 CPU 限制: \(kLowPowerMinFrequencyMHz)-\(kLowPowerMaxFrequencyMHz)MHz controller:\(controller)")
}

// 简化: 使用 extend 方法在 MRC 模式下通过 ObjC 的 perform:withObject: 调多参数方法
private func callVoidIntMethod(_ object: AnyObject, _ sel: Selector, _ value: Int) {
    _ = object.perform(sel, with: value)
}

// MARK: - C 函数钩子类型别名

private typealias IOServiceOpenFunc = @convention(c) (io_service_t, task_t, UInt32, UnsafeMutablePointer<io_connect_t>) -> kern_return_t
private typealias IOConnectCallMethodFunc = @convention(c) (mach_port_t, UInt32, UnsafePointer<UInt64>?, UInt32, UnsafeRawPointer?, Int, UnsafeMutablePointer<UInt64>?, UnsafeMutablePointer<UInt32>?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int>?) -> kern_return_t
private typealias IOServiceSetPropertyFunc = @convention(c) (io_service_t, CFString?, CFTypeRef?) -> kern_return_t
private typealias NotifyPostFunc = @convention(c) (UnsafePointer<CChar>?) -> UInt32
private typealias GetConfigurationForFunc = @convention(c) (CFString?) -> Unmanaged<CFDictionary>?

// MARK: - C 函数钩子原始指针存储

private var origPtr_IOServiceOpen: UnsafeMutableRawPointer?
private var origPtr_IOConnectCallMethod: UnsafeMutableRawPointer?
private var origPtr_IOServiceSetProperty: UnsafeMutableRawPointer?
private var origPtr_notify_post: UnsafeMutableRawPointer?
private var origPtr_getConfigurationFor: UnsafeMutableRawPointer?

// MARK: - IOKit 钩子实现

private let new_IOServiceOpen: IOServiceOpenFunc = { service, task, type, connect in
    let ret = unsafeBitCast(origPtr_IOServiceOpen, to: IOServiceOpenFunc.self)(service, task, type, connect)
    if ret == KERN_SUCCESS {
        trackConnection(connect.pointee, isThermal: serviceIsThermal(service))
    }
    return ret
}

private let new_IOConnectCallMethod: IOConnectCallMethodFunc = { connection, selector, input, inputCnt, inputStruct, inputStructCnt, output, outputCnt, outputStruct, outputStructCnt in
    if !g_enabled || !isThermalConnection(connection) || g_restoringFullPower {
        return unsafeBitCast(origPtr_IOConnectCallMethod, to: IOConnectCallMethodFunc.self)(connection, selector, input, inputCnt, inputStruct, inputStructCnt, output, outputCnt, outputStruct, outputStructCnt)
    }
    if selectorIsCritical(selector) || isTemperatureAboveSafetyCeiling() {
        return unsafeBitCast(origPtr_IOConnectCallMethod, to: IOConnectCallMethodFunc.self)(connection, selector, input, inputCnt, inputStruct, inputStructCnt, output, outputCnt, outputStruct, outputStructCnt)
    }
    if shouldApplyFullCPUProtection() && selectorIsMitigation(selector) {
        return KERN_SUCCESS
    }
    return unsafeBitCast(origPtr_IOConnectCallMethod, to: IOConnectCallMethodFunc.self)(connection, selector, input, inputCnt, inputStruct, inputStructCnt, output, outputCnt, outputStruct, outputStructCnt)
}

private let new_IOServiceSetProperty: IOServiceSetPropertyFunc = { service, key, value in
    guard g_enabled, let ks = key as? String else {
        return unsafeBitCast(origPtr_IOServiceSetProperty, to: IOServiceSetPropertyFunc.self)(service, key, value)
    }
    if isTemperatureAboveSafetyCeiling() {
        return unsafeBitCast(origPtr_IOServiceSetProperty, to: IOServiceSetPropertyFunc.self)(service, key, value)
    }
    if g_cpuProtection {
        if g_restoringFullPower {
            return unsafeBitCast(origPtr_IOServiceSetProperty, to: IOServiceSetPropertyFunc.self)(service, key, value)
        }
        let cpuKeys: [String] = ["cpu", "CPU", "freq", "Freq", "frequency", "performance", "throttle", "mitigation", "speed", "limit"]
        for k in cpuKeys {
            if ks.contains(k) {
                if isFullPowerMode { return KERN_SUCCESS }
                if shouldApplyLowPowerLimit(), let replacement = copyLowPowerFrequencyValueForKey(ks, value) {
                    return unsafeBitCast(origPtr_IOServiceSetProperty, to: IOServiceSetPropertyFunc.self)(service, key, replacement)
                }
                break
            }
        }
    }
    if g_brightnessProtection, shouldBlockBrightnessProperty(ks, value) {
        return KERN_SUCCESS
    }
    return unsafeBitCast(origPtr_IOServiceSetProperty, to: IOServiceSetPropertyFunc.self)(service, key, value)
}

private let new_notify_post: NotifyPostFunc = { name in
    if g_enabled, g_suppressThermalNotifications, let name = name {
        if !isTemperatureAboveSafetyCeiling() {
            let ns = String(cString: name)
            if isThermalNotificationName(ns) {
                return NOTIFY_STATUS_OK
            }
        }
    }
    return unsafeBitCast(origPtr_notify_post, to: NotifyPostFunc.self)(name)
}

private let new_getConfigurationFor: GetConfigurationForFunc = { key in
    let origFunc = unsafeBitCast(origPtr_getConfigurationFor, to: GetConfigurationForFunc.self)
    guard let config = origFunc(key)?.takeRetainedValue() as? [AnyHashable: Any] else {
        return nil
    }
    guard g_enabled, g_cpuProtection, !isTemperatureAboveSafetyCeiling() else {
        return Unmanaged.passRetained(config as CFDictionary)
    }

    if isLowPowerMode {
        let patched = patchedLowPowerConfigObject(config as NSDictionary, nil) as? [AnyHashable: Any] ?? config
        var lowPowerConfig = patched
        if var powerSaveParams = patched["powerSaveParams"] as? [AnyHashable: Any] {
            powerSaveParams["PackageLowPowerTarget"] = lowPowerTargetValue()
            powerSaveParams["CPULowPowerTarget"] = lowPowerTargetValue()
            lowPowerConfig["powerSaveParams"] = powerSaveParams
        }
        NSLog("CPUthermal 已应用低功耗配置 target:\(lowPowerTargetValue()) (\(kLowPowerMinFrequencyMHz)-\(kLowPowerMaxFrequencyMHz)MHz)")
        return Unmanaged.passRetained(lowPowerConfig as CFDictionary)
    }

    var modified = config
    let tempThresholdKeys: [String] = [
        "thermalThresholds", "dieTemperatureThresholds", "skinTemperatureThresholds",
        "componentTemperatureThresholds", "hotTemperatureThresholds"
    ]
    for tk in tempThresholdKeys {
        if let thresholds = modified[tk] as? [NSNumber] {
            modified[tk] = thresholds.map { NSNumber(value: $0.int64Value + 5000) }
        } else if let thresholds = modified[tk] as? [AnyHashable: Any] {
            var newDict: [AnyHashable: Any] = [:]
            for (k, v) in thresholds {
                if let num = v as? NSNumber {
                    newDict[k] = NSNumber(value: num.int64Value + 5000)
                } else {
                    newDict[k] = v
                }
            }
            modified[tk] = newDict
        }
    }
    NSLog("CPUthermal 已修改热配置表")
    return Unmanaged.passRetained(modified as CFDictionary)
}

// MARK: - ObjC 钩子安装

private func installCFunctionHooks() {
    NSLog("CPUthermal 开始安装 C 函数钩子...")

    // IOServiceOpen
    if let IOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) {
        if let sym = dlsym(IOKit, "IOServiceOpen") {
            MSHookFunction(sym, unsafeBitCast(new_IOServiceOpen as IOServiceOpenFunc, to: UnsafeMutableRawPointer.self), &origPtr_IOServiceOpen)
            NSLog("CPUthermal IOServiceOpen hook 已安装")
        }
        if let sym = dlsym(IOKit, "IOConnectCallMethod") {
            MSHookFunction(sym, unsafeBitCast(new_IOConnectCallMethod as IOConnectCallMethodFunc, to: UnsafeMutableRawPointer.self), &origPtr_IOConnectCallMethod)
            NSLog("CPUthermal IOConnectCallMethod hook 已安装")
        }
        if let sym = dlsym(IOKit, "IOServiceSetProperty") {
            MSHookFunction(sym, unsafeBitCast(new_IOServiceSetProperty as IOServiceSetPropertyFunc, to: UnsafeMutableRawPointer.self), &origPtr_IOServiceSetProperty)
            NSLog("CPUthermal IOServiceSetProperty hook 已安装")
        }
    } else {
        NSLog("CPUthermal 警告: IOKit 框架加载失败")
    }

    // notify_post
    if let sym = dlsym(RTLD_DEFAULT, "notify_post") {
        MSHookFunction(sym, unsafeBitCast(new_notify_post as NotifyPostFunc, to: UnsafeMutableRawPointer.self), &origPtr_notify_post)
        NSLog("CPUthermal notify_post hook 已安装")
    }

    // _getConfigurationFor
    if let monitor = dlopen("/System/Library/PrivateFrameworks/DeviceMonitor.framework/DeviceMonitor", RTLD_NOW) {
        if let sym = dlsym(monitor, "_getConfigurationFor") {
            MSHookFunction(sym, unsafeBitCast(new_getConfigurationFor as GetConfigurationForFunc, to: UnsafeMutableRawPointer.self), &origPtr_getConfigurationFor)
            NSLog("CPUthermal _getConfigurationFor hook 已安装")
        } else {
            NSLog("CPUthermal 未找到 _getConfigurationFor (非致命)")
        }
    } else {
        NSLog("CPUthermal 未找到 DeviceMonitor.framework (非致命)")
    }

    // 安装 ObjC 类钩子
    installObjCHooks()

    NSLog("CPUthermal 温控防护已激活 — 安全阀:\(kSafetyTempThreshold / 1000)°C CPU性能:\(g_cpuProtection) 亮度:\(g_brightnessProtection) 通知:\(g_suppressThermalNotifications) CPMS:\(g_keepCPSMAlive)")
}

// MARK: - 脉冲调度

private func applyLowPowerToCommonProduct() {
    guard let product = g_commonProduct else { return }
    g_restoringFullPower = true
    defer { g_restoringFullPower = false }
    let setCPULevelSel = NSSelectorFromString("setCPULevel:")
    if product.responds(to: setCPULevelSel) {
        _ = product.perform(setCPULevelSel, with: 1)
    }
    let setPowerCeilSel = NSSelectorFromString("setCPUPowerCeiling:fromDecisionSource:")
    if product.responds(to: setPowerCeilSel) {
        _ = product.perform(setPowerCeilSel, with: lowPowerPowerCeilingValue(), with: "CPUthermal")
    }
    let setGPUCeilSel = NSSelectorFromString("setGPUPowerCeiling:fromDecisionSource:")
    if product.responds(to: setGPUCeilSel) {
        _ = product.perform(setGPUCeilSel, with: lowPowerPowerCeilingValue(), with: "CPUthermal")
    }
    let setPackageCeilSel = NSSelectorFromString("setPackagePowerCeiling:fromDecisionSource:")
    if product.responds(to: setPackageCeilSel) {
        _ = product.perform(setPackageCeilSel, with: lowPowerPowerCeilingValue(), with: "CPUthermal")
    }
    NSLog("CPUthermal 已主动套用低功耗 CommonProduct 状态")
}

private func applyFullPowerToCommonProduct() {
    guard let product = g_commonProduct else { return }
    g_restoringFullPower = true
    defer { g_restoringFullPower = false }
    let setCPMSEnabledSel = NSSelectorFromString("setCPMSMitigationsEnabled:")
    if product.responds(to: setCPMSEnabledSel), !g_keepCPSMAlive {
        _ = product.perform(setCPMSEnabledSel, with: false)
    }
    let setCPULevelSel = NSSelectorFromString("setCPULevel:")
    if product.responds(to: setCPULevelSel) {
        _ = product.perform(setCPULevelSel, with: 0)
    }
    let setPowerCeilSel = NSSelectorFromString("setCPUPowerCeiling:fromDecisionSource:")
    if product.responds(to: setPowerCeilSel) {
        _ = product.perform(setPowerCeilSel, with: 0, with: "CPUthermal")
    }
    let setThermalSel = NSSelectorFromString("setThermalState:")
    if product.responds(to: setThermalSel) {
        _ = product.perform(setThermalSel, with: 0)
    }
    NSLog("CPUthermal 已主动套用防温控 CommonProduct 状态")
}

private func applyCurrentPowerModeToRuntime() {
    applyPowerModeToRuntime(respectBootGuard: true)
}

private func applyPowerModeToRuntime(respectBootGuard: Bool) {
    guard g_enabled, g_cpuProtection else { return }
    if isLowPowerMode {
        applyLowPowerToCommonProduct()
        scheduleLowPowerApplyPulse()
        return
    }
    if isFullPowerMode {
        if respectBootGuard && fullPowerBootGuardActive() {
            let elapsed = CFAbsoluteTimeGetCurrent() - g_processStartTime
            let remaining = kFullPowerBootGuardDuration - elapsed
            scheduleDeferredRuntimeApply(max(remaining, 0.1) + 0.1)
            return
        }
        applyFullPowerToCommonProduct()
        scheduleFullPowerRecoveryPulse()
    }
}

private var g_hooksInstalled = false

private func scheduleDeferredRuntimeApply(_ delay: Double) {
    guard !g_deferredRuntimeApplyScheduled else { return }
    g_deferredRuntimeApplyScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        g_deferredRuntimeApplyScheduled = false
        applyCurrentPowerModeToRuntime()
    }
}

private func scheduleLowPowerApplyPulse() {
    guard !g_lowPowerApplyPulseScheduled, g_enabled, g_cpuProtection, isLowPowerMode else { return }
    g_lowPowerApplyPulseScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        runLowPowerApplyPulse(remaining: 8, delay: 0.1)
    }
}

private func runLowPowerApplyPulse(remaining: Int, delay: Double) {
    guard remaining > 0, g_enabled, g_cpuProtection, isLowPowerMode else {
        g_lowPowerApplyPulseScheduled = false
        return
    }
    applyLowPowerToCommonProduct()
    if remaining <= 1 {
        g_lowPowerApplyPulseScheduled = false
        return
    }
    let nextDelay = min(delay * 1.5, 1.0)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        runLowPowerApplyPulse(remaining: remaining - 1, delay: nextDelay)
    }
}

private func scheduleFullPowerRecoveryPulse() {
    guard !g_fullPowerRecoveryPulseScheduled, g_enabled, g_cpuProtection, isFullPowerMode else { return }
    g_fullPowerRecoveryPulseScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        runFullPowerRecoveryPulse(remaining: 4, delay: 0.15)
    }
}

private func runFullPowerRecoveryPulse(remaining: Int, delay: Double) {
    guard remaining > 0, g_enabled, g_cpuProtection, isFullPowerMode else {
        g_fullPowerRecoveryPulseScheduled = false
        return
    }
    applyFullPowerToCommonProduct()
    if remaining <= 1 {
        g_fullPowerRecoveryPulseScheduled = false
        return
    }
    let nextDelay = min(delay * 1.5, 1.0)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        runFullPowerRecoveryPulse(remaining: remaining - 1, delay: nextDelay)
    }
}

private func scheduleWakeRuntimeApply() {
    guard !g_wakeRuntimeApplyScheduled, g_enabled, g_cpuProtection else { return }
    g_wakeRuntimeApplyScheduled = true
    DispatchQueue.main.async {
        runWakeRuntimeApplyPulse(remaining: 8, delay: 0.3)
    }
}

private func runWakeRuntimeApplyPulse(remaining: Int, delay: Double) {
    guard remaining > 0, g_enabled, g_cpuProtection else {
        g_wakeRuntimeApplyScheduled = false
        return
    }
    loadPrefs()
    applyPowerModeToRuntime(respectBootGuard: false)
    if remaining <= 1 {
        g_wakeRuntimeApplyScheduled = false
        return
    }
    let nextDelay = min(delay * 1.4, 1.0)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        runWakeRuntimeApplyPulse(remaining: remaining - 1, delay: nextDelay)
    }
}

// MARK: - Puppet 事件 & 通知回调

private func executePuppetEvent() {
    guard let product = g_commonProduct else { return }
    let level = (readPrefsDictionary()?["thermalPuppetValue"] as? String) ?? "nominal"
    let sel = NSSelectorFromString("putDeviceInThermalSimulationMode:")
    _ = product.perform(sel, with: level)
    NSLog("CPUthermal Puppet 事件: 热模式设为 \(level)")
}

private let onPuppetEvent: CFNotificationCallback = { _, _, _, _, _ in
    executePuppetEvent()
}

private let onPowerModeChanged: CFNotificationCallback = { _, _, _, _, _ in
    loadPrefs()
    applyPowerModeToRuntime(respectBootGuard: false)
    NSLog("CPUthermal 功率模式已切换: \(isLowPowerMode ? "低功耗" : "防温控")")
}

private let onSettingsChanged: CFNotificationCallback = { _, _, _, _, _ in
    loadPrefs()
    if g_enabled {
        applyPowerModeToRuntime(respectBootGuard: false)
    }
    NSLog("CPUthermal 设置已重载 enabled:\(g_enabled) CPU:\(g_cpuProtection) 亮度:\(g_brightnessProtection) 通知:\(g_suppressThermalNotifications)")
}

private let onWakeRuntime: CFNotificationCallback = { _, _, _, _, _ in
    loadPrefs()
    if g_enabled {
        scheduleWakeRuntimeApply()
    }
    NSLog("CPUthermal 收到唤醒/亮屏事件，准备恢复当前功率模式")
}

// MARK: - ObjC Hook 实现 (MSHookMessageEx)

private let thermalManagerClass: AnyClass = objc_getClass("ThermalManager") as! AnyClass
private let commonProductClass: AnyClass = objc_getClass("CommonProduct") as! AnyClass
private let thermalControlClass: AnyClass = objc_getClass("ThermalControl") as! AnyClass
private let ApplePPMCPUClass: AnyClass = objc_getClass("ApplePPMCPU") as! AnyClass
private let mitigationControllerClass: AnyClass = objc_getClass("MitigationController") as! AnyClass

private func installObjCHooks() {
    installInitProductHook()
    installTryTakeActionHook()
    installSimulateLightThermalPressureHook()
    installUpdatePowerzoneTelemetryHook()
    installThermalManagerHooks()
    installThermalControlHooks()
    installApplePPMCPUHooks()
    installMitigationControllerHooks()
}

// MARK: CommonProduct Hooks
private func installInitProductHook() {
    let sel = NSSelectorFromString("initProduct:")
    let cls: AnyClass = commonProductClass
    let method = class_getInstanceMethod(cls, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { self, arg1 in
        typealias OrigFunc = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
        let result = unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, arg1)
        if g_enabled {
            g_commonProduct = self
            let putSel = NSSelectorFromString("putDeviceInThermalSimulationMode:")
            _ = self.perform(putSel, with: "nominal")
            applyCurrentPowerModeToRuntime()
            NSLog("CPUthermal CommonProduct init, 已重置热状态为 nominal, 功率模式:\(isLowPowerMode ? "低功耗" : "防温控")")
        }
        return result
    }
    MSHookMessageEx(cls, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installTryTakeActionHook() {
    let sel = NSSelectorFromString("tryTakeAction")
    let method = class_getInstanceMethod(commonProductClass, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject) -> Void = { self in
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() { return }
        typealias OrigFunc = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel)
    }
    MSHookMessageEx(commonProductClass, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installSimulateLightThermalPressureHook() {
    let sel = NSSelectorFromString("simulateLightThermalPressure")
    let method = class_getInstanceMethod(commonProductClass, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject) -> Void = { self in
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() { return }
        typealias OrigFunc = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel)
    }
    MSHookMessageEx(commonProductClass, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installUpdatePowerzoneTelemetryHook() {
    let sel = NSSelectorFromString("updatePowerzoneTelemetry")
    let method = class_getInstanceMethod(commonProductClass, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject) -> Void = { self in
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() { return }
        typealias OrigFunc = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel)
    }
    MSHookMessageEx(commonProductClass, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

// MARK: ThermalManager Hooks
private func installThermalManagerHooks() {
    // evaluateDecisionTree
    installHook(cls: thermalManagerClass, sel: NSSelectorFromString("evaluateDecisionTree")) { self in
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() {
            NSLog("CPUthermal 阻止决策树评估 (evaluateDecisionTree)")
            return
        }
        callOrigVoid(cls: thermalManagerClass, sel: NSSelectorFromString("evaluateDecisionTree"), self: self)
    }
    // updateThermalNotification:
    installHookWithArg(cls: thermalManagerClass, sel: NSSelectorFromString("updateThermalNotification:")) { self, arg in
        if g_enabled, g_suppressThermalNotifications, !isTemperatureAboveSafetyCeiling() {
            NSLog("CPUthermal 阻止热通知: \(String(describing: arg))")
            return
        }
        callOrigVoidWithArg(cls: thermalManagerClass, sel: NSSelectorFromString("updateThermalNotification:"), self: self, arg: arg)
    }
    // getReleaseRateForComponent:
    installHookWithArgReturn(cls: thermalManagerClass, sel: NSSelectorFromString("getReleaseRateForComponent:")) { self, arg in
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() {
            let rate = callOrigFloatWithArg(cls: thermalManagerClass, sel: NSSelectorFromString("getReleaseRateForComponent:"), self: self, arg: arg)
            let newRate = rate > 0.5 ? rate * 0.5 : rate
            NSLog("CPUthermal 软化释放速率: \(String(describing: arg)) -> \(newRate)")
            return newRate
        }
        return callOrigFloatWithArg(cls: thermalManagerClass, sel: NSSelectorFromString("getReleaseRateForComponent:"), self: self, arg: arg)
    }
    // getBatteryServiceSuggestion:
    installHookWithArgReturnId(cls: thermalManagerClass, sel: NSSelectorFromString("getBatteryServiceSuggestion:")) { self, arg in
        let result = callOrigIdWithArg(cls: thermalManagerClass, sel: NSSelectorFromString("getBatteryServiceSuggestion:"), self: self, arg: arg)
        if g_enabled, g_suppressThermalNotifications, !isTemperatureAboveSafetyCeiling() {
            NSLog("CPUthermal 拦截 ThermalManager 散热建议")
            return nil
        }
        return result
    }
}

// MARK: ThermalControl Hooks
private func installThermalControlHooks() {
    // initForFastLoop:noDisplay:powerSaveParams:powerZoneParams:
    let sel = NSSelectorFromString("initForFastLoop:noDisplay:powerSaveParams:powerZoneParams:")
    let method = class_getInstanceMethod(thermalControlClass, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, Bool, Bool, AnyObject?, AnyObject?) -> AnyObject? = { self, fast, noDisplay, saveParams, zoneParams in
        typealias OrigFunc = @convention(c) (AnyObject, Selector, Bool, Bool, AnyObject?, AnyObject?) -> AnyObject?
        let result = unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, fast, noDisplay, saveParams, zoneParams)
        if let r = result {
            trackPowerController(r)
            applyCurrentPowerModeToRuntime()
        }
        return result
    }
    MSHookMessageEx(thermalControlClass, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)

    // initWithParams:
    let sel2 = NSSelectorFromString("initWithParams:")
    let method2 = class_getInstanceMethod(thermalControlClass, sel2)!
    let origIMP2 = method_getImplementation(method2)
    let block2: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { self, params in
        typealias OrigFunc = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
        let result = unsafeBitCast(origIMP2, to: OrigFunc.self)(self, sel2, params)
        if let r = result {
            trackPowerController(r)
            applyCurrentPowerModeToRuntime()
        }
        return result
    }
    MSHookMessageEx(thermalControlClass, sel2, imp_implementationWithBlock(unsafeBitCast(block2, to: AnyObject.self)), nil)

    // powerSaveActive
    installPowerSaveActiveHook(cls: thermalControlClass)

    // setPowerSaveActive:
    installSetPowerSaveActiveHook(cls: thermalControlClass)

    // setPowerSaveToken:
    installSetPowerSaveTokenHook(cls: thermalControlClass)

    // calculateControlEffort:trigger:
    installCalculateControlEffortHook(cls: thermalControlClass)

    // actionComponentControl
    installActionComponentControlHook(cls: thermalControlClass)

    // readReleaseRateForAllComponents
    installReadReleaseRateForAllComponentsHook(cls: thermalControlClass)
}

// MARK: ApplePPMCPU Hooks
private func installApplePPMCPUHooks() {
    // setCPULevel:
    let sel = NSSelectorFromString("setCPULevel:")
    let method = class_getInstanceMethod(ApplePPMCPUClass, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, Int) -> Void = { self, level in
        typealias OrigFunc = @convention(c) (AnyObject, Selector, Int) -> Void
        if g_restoringFullPower {
            unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, level)
            return
        }
        if shouldApplyLowPowerLimit(), !isTemperatureAboveSafetyCeiling() {
            let clamped = max(0, min(level, 2))
            unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, clamped)
            return
        }
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() {
            unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, 0)
            return
        }
        unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, level)
    }
    MSHookMessageEx(ApplePPMCPUClass, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)

    // updateCPU
    let sel2 = NSSelectorFromString("updateCPU")
    let method2 = class_getInstanceMethod(ApplePPMCPUClass, sel2)!
    let origIMP2 = method_getImplementation(method2)
    let block2: @convention(block) (AnyObject) -> Void = { self in
        if g_restoringFullPower {
            typealias OrigFunc = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(origIMP2, to: OrigFunc.self)(self, sel2)
            return
        }
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() { return }
        typealias OrigFunc = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(origIMP2, to: OrigFunc.self)(self, sel2)
    }
    MSHookMessageEx(ApplePPMCPUClass, sel2, imp_implementationWithBlock(unsafeBitCast(block2, to: AnyObject.self)), nil)
}

// MARK: MitigationController Hooks
private func installMitigationControllerHooks() {
    // initForFastLoop:noDisplay:powerSaveParams:powerZoneParams:
    let sel = NSSelectorFromString("initForFastLoop:noDisplay:powerSaveParams:powerZoneParams:")
    let method = class_getInstanceMethod(mitigationControllerClass, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, Bool, Bool, AnyObject?, AnyObject?) -> AnyObject? = { self, fast, noDisplay, saveParams, zoneParams in
        typealias OrigFunc = @convention(c) (AnyObject, Selector, Bool, Bool, AnyObject?, AnyObject?) -> AnyObject?
        let result = unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, fast, noDisplay, saveParams, zoneParams)
        if let r = result {
            trackPowerController(r)
            applyCurrentPowerModeToRuntime()
        }
        return result
    }
    MSHookMessageEx(mitigationControllerClass, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)

    // powerSaveActive / setPowerSaveActive: / setPowerSaveToken:
    installPowerSaveActiveHook(cls: mitigationControllerClass)
    installSetPowerSaveActiveHook(cls: mitigationControllerClass)
    installSetPowerSaveTokenHook(cls: mitigationControllerClass)

    // updateCPU
    installVoidUpdateHook(cls: mitigationControllerClass, sel: NSSelectorFromString("updateCPU"))
    // updateGPU
    installVoidUpdateHook(cls: mitigationControllerClass, sel: NSSelectorFromString("updateGPU"))
    // updatePackage
    installVoidUpdateHook(cls: mitigationControllerClass, sel: NSSelectorFromString("updatePackage"))

    // setCPULowPowerTarget:
    installSetCPULowPowerTargetHook()

    // setPackageLowPowerTarget
    let sel6 = NSSelectorFromString("setPackageLowPowerTarget")
    let method6 = class_getInstanceMethod(mitigationControllerClass, sel6)!
    let origIMP6 = method_getImplementation(method6)
    let block6: @convention(block) (AnyObject) -> Void = { self in
        typealias OrigFunc = @convention(c) (AnyObject, Selector) -> Void
        if g_restoringFullPower {
            unsafeBitCast(origIMP6, to: OrigFunc.self)(self, sel6)
            return
        }
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() { return }
        unsafeBitCast(origIMP6, to: OrigFunc.self)(self, sel6)
    }
    MSHookMessageEx(mitigationControllerClass, sel6, imp_implementationWithBlock(unsafeBitCast(block6, to: AnyObject.self)), nil)

    // setMaxCPUPowerTarget:useLegacyPath:setProperty:
    installSetMaxCPUPowerTargetHook()

    // setCPUPowerCeiling:fromDecisionSource:
    installSetCPUPowerCeilingHook()

    // setCPUPowerFloor:fromDecisionSource:
    installSetCPUPowerFloorHook()

    // setCPUPowerZoneTarget:
    installSetCPUPowerZoneTargetHook()
}

// MARK: - 通用 Hook 辅助

private typealias VoidFunc = @convention(c) (AnyObject, Selector) -> Void
private typealias VoidIntFunc = @convention(c) (AnyObject, Selector, Int) -> Void
private typealias IdFunc = @convention(c) (AnyObject, Selector, Int, Bool, UnsafeMutableRawPointer) -> Void
private typealias IntArgFunc = @convention(c) (AnyObject, Selector, Int, UnsafeMutableRawPointer) -> Void
private typealias BoolArgFunc = @convention(c) (AnyObject, Selector, Bool) -> Void
private typealias ObjcBoolArgFunc = @convention(c) (AnyObject, Selector, ObjCBool) -> Void

private func installHook(cls: AnyClass, sel: Selector, body: @escaping (AnyObject) -> Void) {
    let method = class_getInstanceMethod(cls, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject) -> Void = { self in
        body(self)
    }
    MSHookMessageEx(cls, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installHookWithArg(cls: AnyClass, sel: Selector, body: @escaping (AnyObject, AnyObject?) -> Void) {
    let method = class_getInstanceMethod(cls, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, AnyObject?) -> Void = { self, arg in
        body(self, arg)
    }
    MSHookMessageEx(cls, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installHookWithArgReturn(cls: AnyClass, sel: Selector, body: @escaping (AnyObject, AnyObject?) -> Float) {
    let method = class_getInstanceMethod(cls, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, AnyObject?) -> Float = { self, arg in
        body(self, arg)
    }
    MSHookMessageEx(cls, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installHookWithArgReturnId(cls: AnyClass, sel: Selector, body: @escaping (AnyObject, AnyObject?) -> AnyObject?) {
    let method = class_getInstanceMethod(cls, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { self, arg in
        body(self, arg)
    }
    MSHookMessageEx(cls, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func callOrigVoid(cls: AnyClass, sel: Selector, self: AnyObject) {
    let method = class_getInstanceMethod(cls, sel)!
    let imp = method_getImplementation(method)
    unsafeBitCast(imp, to: VoidFunc.self)(`self`, sel)
}

private func callOrigVoidWithArg(cls: AnyClass, sel: Selector, self: AnyObject, arg: AnyObject?) {
    let method = class_getInstanceMethod(cls, sel)!
    let imp = method_getImplementation(method)
    typealias Func = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    unsafeBitCast(imp, to: Func.self)(`self`, sel, arg)
}

private func callOrigFloatWithArg(cls: AnyClass, sel: Selector, self: AnyObject, arg: AnyObject?) -> Float {
    let method = class_getInstanceMethod(cls, sel)!
    let imp = method_getImplementation(method)
    typealias Func = @convention(c) (AnyObject, Selector, AnyObject?) -> Float
    return unsafeBitCast(imp, to: Func.self)(`self`, sel, arg)
}

private func callOrigIdWithArg(cls: AnyClass, sel: Selector, self: AnyObject, arg: AnyObject?) -> AnyObject? {
    let method = class_getInstanceMethod(cls, sel)!
    let imp = method_getImplementation(method)
    typealias Func = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
    return unsafeBitCast(imp, to: Func.self)(`self`, sel, arg)
}

// MARK: - PowerSaveActive/SetPowerSaveActive/SetPowerSaveToken 通用钩子

private func installPowerSaveActiveHook(cls: AnyClass) {
    let sel = NSSelectorFromString("powerSaveActive")
    let method = class_getInstanceMethod(cls, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject) -> Bool = { self in
        typealias OrigFunc = @convention(c) (AnyObject, Selector) -> Bool
        if g_restoringFullPower { return unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel) }
        if shouldApplyLowPowerLimit(), !isTemperatureAboveSafetyCeiling() { return true }
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() { return false }
        return unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel)
    }
    MSHookMessageEx(cls, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installSetPowerSaveActiveHook(cls: AnyClass) {
    let sel = NSSelectorFromString("setPowerSaveActive:")
    let method = class_getInstanceMethod(cls, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, Bool) -> Void = { self, active in
        typealias OrigFunc = @convention(c) (AnyObject, Selector, Bool) -> Void
        if g_restoringFullPower { unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, active); return }
        if shouldApplyLowPowerLimit(), !isTemperatureAboveSafetyCeiling() { unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, true); return }
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() { unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, false); return }
        unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, active)
    }
    MSHookMessageEx(cls, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installSetPowerSaveTokenHook(cls: AnyClass) {
    let sel = NSSelectorFromString("setPowerSaveToken:")
    let method = class_getInstanceMethod(cls, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, AnyObject?) -> Void = { self, token in
        typealias OrigFunc = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        if g_restoringFullPower { unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, token); return }
        if shouldApplyLowPowerLimit(), !isTemperatureAboveSafetyCeiling() { unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, 1); return }
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() { unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, nil); return }
        unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, token)
    }
    MSHookMessageEx(cls, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

// MARK: - calculateControlEffort / actionComponentControl / readReleaseRateForAllComponents / voidUpdate

private func installCalculateControlEffortHook(cls: AnyClass) {
    let sel = NSSelectorFromString("calculateControlEffort:trigger:")
    let method = class_getInstanceMethod(cls, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Float = { self, trigger, arg2 in
        typealias OrigFunc = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Float
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() {
            let effort = unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, trigger, arg2)
            let newEffort = effort * 0.5
            NSLog("CPUthermal 软化控制力度: \(effort) -> \(newEffort)")
            return newEffort
        }
        return unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, trigger, arg2)
    }
    MSHookMessageEx(cls, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installActionComponentControlHook(cls: AnyClass) {
    let sel = NSSelectorFromString("actionComponentControl")
    let method = class_getInstanceMethod(cls, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject) -> Void = { self in
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() {
            NSLog("CPUthermal 阻止 actionComponentControl")
            return
        }
        typealias OrigFunc = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel)
    }
    MSHookMessageEx(cls, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installReadReleaseRateForAllComponentsHook(cls: AnyClass) {
    let sel = NSSelectorFromString("readReleaseRateForAllComponents")
    let method = class_getInstanceMethod(cls, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject) -> Void = { self in
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() {
            NSLog("CPUthermal 阻止 readReleaseRateForAllComponents")
            return
        }
        typealias OrigFunc = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel)
    }
    MSHookMessageEx(cls, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installVoidUpdateHook(cls: AnyClass, sel: Selector) {
    let method = class_getInstanceMethod(cls, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject) -> Void = { self in
        if g_restoringFullPower {
            typealias OrigFunc = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel)
            return
        }
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() { return }
        typealias OrigFunc = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel)
    }
    MSHookMessageEx(cls, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

// MARK: - MitigationController 专用钩子

private func installSetCPULowPowerTargetHook() {
    let sel = NSSelectorFromString("setCPULowPowerTarget:")
    let method = class_getInstanceMethod(mitigationControllerClass, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, Int) -> Void = { self, target in
        typealias OrigFunc = @convention(c) (AnyObject, Selector, Int) -> Void
        if g_restoringFullPower { unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, target); return }
        if shouldApplyLowPowerLimit(), !isTemperatureAboveSafetyCeiling() { unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, lowPowerTargetValue()); return }
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() { return }
        unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, target)
    }
    MSHookMessageEx(mitigationControllerClass, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installSetMaxCPUPowerTargetHook() {
    let sel = NSSelectorFromString("setMaxCPUPowerTarget:useLegacyPath:setProperty:")
    let method = class_getInstanceMethod(mitigationControllerClass, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, Int, Bool, UnsafeMutableRawPointer) -> Void = { self, target, legacy, property in
        typealias OrigFunc = @convention(c) (AnyObject, Selector, Int, Bool, UnsafeMutableRawPointer) -> Void
        let propArg = normalizedPropertyArg(self, property)
        if g_restoringFullPower { unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, target, legacy, propArg); return }
        if shouldApplyLowPowerLimit(), !isTemperatureAboveSafetyCeiling() {
            rememberOriginalIntValue(self, "MaxCPUPowerTarget", target)
            let clamped = Int(clampLowPowerFrequencyValue(Int64(target)))
            unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, clamped, legacy, propArg)
            return
        }
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() {
            unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, fullPowerTargetForController(self), legacy, propArg)
            return
        }
        unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, target, legacy, propArg)
    }
    MSHookMessageEx(mitigationControllerClass, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installSetCPUPowerCeilingHook() {
    let sel = NSSelectorFromString("setCPUPowerCeiling:fromDecisionSource:")
    let method = class_getInstanceMethod(mitigationControllerClass, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, Int, UnsafeMutableRawPointer) -> Void = { self, ceiling, source in
        typealias OrigFunc = @convention(c) (AnyObject, Selector, Int, UnsafeMutableRawPointer) -> Void
        if g_restoringFullPower { unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, ceiling, source); return }
        if shouldApplyLowPowerLimit(), !isTemperatureAboveSafetyCeiling() {
            rememberOriginalIntValue(self, "CPUPowerCeiling", ceiling)
            unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, lowPowerPowerCeilingValue(), source)
            return
        }
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() {
            unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, fullPowerCeilingForController(self), source)
            return
        }
        unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, ceiling, source)
    }
    MSHookMessageEx(mitigationControllerClass, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installSetCPUPowerFloorHook() {
    let sel = NSSelectorFromString("setCPUPowerFloor:fromDecisionSource:")
    let method = class_getInstanceMethod(mitigationControllerClass, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, Int, UnsafeMutableRawPointer) -> Void = { self, floor, source in
        typealias OrigFunc = @convention(c) (AnyObject, Selector, Int, UnsafeMutableRawPointer) -> Void
        if g_restoringFullPower { unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, floor, source); return }
        if shouldApplyLowPowerLimit(), !isTemperatureAboveSafetyCeiling() {
            rememberOriginalIntValue(self, "CPUPowerFloor", floor)
            unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, lowPowerPowerFloorValue(), source)
            return
        }
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() {
            unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, fullPowerFloorForController(self), source)
            return
        }
        unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, floor, source)
    }
    MSHookMessageEx(mitigationControllerClass, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

private func installSetCPUPowerZoneTargetHook() {
    let sel = NSSelectorFromString("setCPUPowerZoneTarget:")
    let method = class_getInstanceMethod(mitigationControllerClass, sel)!
    let origIMP = method_getImplementation(method)
    let block: @convention(block) (AnyObject, Int) -> Void = { self, target in
        typealias OrigFunc = @convention(c) (AnyObject, Selector, Int) -> Void
        if g_restoringFullPower { unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, target); return }
        if shouldApplyLowPowerLimit(), !isTemperatureAboveSafetyCeiling() {
            rememberOriginalIntValue(self, "CPUPowerZoneTarget", target)
            let clamped = Int(clampLowPowerFrequencyValue(Int64(target)))
            unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, clamped)
            return
        }
        if shouldApplyFullCPUProtection(), !isTemperatureAboveSafetyCeiling() {
            unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, fullPowerZoneTargetForController(self))
            return
        }
        unsafeBitCast(origIMP, to: OrigFunc.self)(self, sel, target)
    }
    MSHookMessageEx(mitigationControllerClass, sel, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), nil)
}

// MARK: - 初始化 (constructor)

private let _initialize: Void = {
    g_processStartTime = CFAbsoluteTimeGetCurrent()
    loadPrefs()
    guard g_enabled else {
        NSLog("CPUthermal 配置关闭，跳过加载")
        return
    }

    // 注册 Darwin 通知
    let c = CFNotificationCenterGetDarwinNotifyCenter()
    if let center = c {
        CFNotificationCenterAddObserver(center, nil, onPuppetEvent,
            CFStringCreateWithCString(kCFAllocatorDefault, "com.huayuarc.CPUthermal.puppet", kCFStringEncodingUTF8), nil,
            .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, onSettingsChanged,
            CFStringCreateWithCString(kCFAllocatorDefault, "com.huayuarc.CPUthermal/settingsChanged", kCFStringEncodingUTF8), nil,
            .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, onPowerModeChanged,
            CFStringCreateWithCString(kCFAllocatorDefault, "com.huayuarc.CPUthermal/powerModeChanged", kCFStringEncodingUTF8), nil,
            .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, onWakeRuntime,
            CFStringCreateWithCString(kCFAllocatorDefault, "com.apple.springboard.hasFinishedUnblankingScreen", kCFStringEncodingUTF8), nil,
            .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, onWakeRuntime,
            CFStringCreateWithCString(kCFAllocatorDefault, "com.apple.springboard.lockstate", kCFStringEncodingUTF8), nil,
            .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, onWakeRuntime,
            CFStringCreateWithCString(kCFAllocatorDefault, "com.apple.iokit.hid.displayStatus", kCFStringEncodingUTF8), nil,
            .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, onWakeRuntime,
            CFStringCreateWithCString(kCFAllocatorDefault, "com.apple.system.awake", kCFStringEncodingUTF8), nil,
            .deliverImmediately)
    }

    // 延迟安装 C 函数钩子
    DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + 1.0) {
        guard !g_hooksInstalled else { return }
        g_hooksInstalled = true
        installCFunctionHooks()
    }

    NSLog("CPUthermal 延迟初始化已安排 — 1 秒后安装 C 函数钩子")
}()
