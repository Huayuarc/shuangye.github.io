import Foundation

enum CPUthermalShared {
    static let prefRootFSPath = "/var/mobile/Library/Preferences/com.huayuarc.CPUthermal.plist"
    static let oldJBPrefRelativePath = "Library/Preferences/com.huayuarc.CPUthermal.plist"
    static let settingsChangedNotification = "com.huayuarc.CPUthermal/settingsChanged"
    static let powerModeChangedNotification = "com.huayuarc.CPUthermal/powerModeChanged"
    static let defaultMaxPCoreFrequencyMHz = 3780

    static var fileManager: FileManager { FileManager.default }

    static var currentPrefPath: String {
        jbRootPath(forRootFSPath: prefRootFSPath)
    }

    static var oldJBRootPrefPath: String {
        let varJB = "/var/jb"
        let resolvedRoot = (try? fileManager.destinationOfSymbolicLink(atPath: varJB)).flatMap { $0.isEmpty ? nil : $0 } ?? varJB
        return (resolvedRoot as NSString).appendingPathComponent(oldJBPrefRelativePath)
    }

    static var legacyPrefPaths: [String] {
        var paths = [oldJBRootPrefPath]
        if !paths.contains(prefRootFSPath) {
            paths.append(prefRootFSPath)
        }
        return paths
    }

    static var toolPath: String? {
        existingExecutablePath(rootFSPath: "/usr/local/bin/CPUthermalTool", fallbacks: [
            "/var/jb/usr/local/bin/CPUthermalTool",
            "/usr/local/bin/CPUthermalTool"
        ])
    }

    static var killallPath: String? {
        existingExecutablePath(rootFSPath: "/usr/bin/killall", fallbacks: [
            "/var/jb/usr/bin/killall",
            "/var/jb/bin/killall",
            "/usr/bin/killall",
            "/bin/killall"
        ])
    }

    static var launchctlPath: String? {
        existingExecutablePath(rootFSPath: "/usr/bin/launchctl", fallbacks: [
            "/var/jb/usr/bin/launchctl",
            "/var/jb/bin/launchctl",
            "/usr/bin/launchctl",
            "/bin/launchctl"
        ])
    }

    static var sbreloadPath: String? {
        existingExecutablePath(rootFSPath: "/usr/bin/sbreload", fallbacks: [
            "/var/jb/usr/bin/sbreload",
            "/var/jb/bin/sbreload",
            "/usr/bin/sbreload"
        ])
    }

    static func jbRootPath(forRootFSPath path: String) -> String {
        let resolved = CPUthermalSwiftJBRootPathForRootFSPath(path)
        return resolved.isEmpty ? path : resolved
    }

    static func hardwareIdentifier() -> String {
        var machine = [CChar](repeating: 0, count: 256)
        var size = machine.count
        if sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0, machine[0] != 0 {
            return String(cString: machine)
        }
        return ""
    }

    static func nativeMaxPCoreFrequencyMHz(for hardware: String = hardwareIdentifier()) -> Int {
        if hardware == hardwareIdentifier() {
            return CPUthermalSwiftNativeMaxPCoreFrequencyMHz()
        }

        switch hardware {
        case "iPhone10,1", "iPhone10,2", "iPhone10,3", "iPhone10,6":
            return 2390
        case "iPhone11,2", "iPhone11,4", "iPhone11,6", "iPhone11,8":
            return 2490
        case "iPhone12,1", "iPhone12,3", "iPhone12,5":
            return 2650
        case "iPhone13,1", "iPhone13,2", "iPhone13,3", "iPhone13,4":
            return 3090
        case "iPhone14,2", "iPhone14,3", "iPhone14,4", "iPhone14,5", "iPhone14,7", "iPhone14,8":
            return 3230
        case "iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5":
            return 3460
        case "iPhone16,1", "iPhone16,2":
            return 3780
        default:
            NSLog("CPUthermal: Unknown hardware '%@', falling back to default max frequency %ld MHz", hardware, defaultMaxPCoreFrequencyMHz)
            return defaultMaxPCoreFrequencyMHz
        }
    }

    static func ensurePrefDirectory() {
        let directory = (currentPrefPath as NSString).deletingLastPathComponent
        try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    static func readMutablePrefs() -> NSMutableDictionary {
        let path = currentPrefPath
        if let prefs = NSMutableDictionary(contentsOfFile: path) {
            return prefs
        }

        for legacyPath in legacyPrefPaths where legacyPath != path {
            guard let legacyPrefs = NSDictionary(contentsOfFile: legacyPath) else { continue }
            let prefs = legacyPrefs.mutableCopy() as? NSMutableDictionary ?? NSMutableDictionary(dictionary: legacyPrefs)
            ensurePrefDirectory()
            if prefs.write(toFile: path, atomically: true) {
                try? fileManager.removeItem(atPath: legacyPath)
            }
            return prefs
        }

        return NSMutableDictionary()
    }

    static func readPrefs() -> NSDictionary {
        readMutablePrefs()
    }

    @discardableResult
    static func writePrefs(_ prefs: NSDictionary) -> Bool {
        ensurePrefDirectory()
        let path = currentPrefPath
        let ok = prefs.write(toFile: path, atomically: true)
        if ok {
            for legacyPath in legacyPrefPaths where legacyPath != path {
                try? fileManager.removeItem(atPath: legacyPath)
            }
        }
        return ok
    }

    static func currentPowerMode() -> String {
        if let mode = readPrefs()["powerMode"] as? String, !mode.isEmpty {
            return mode
        }
        return "fullPower"
    }

    static func savePowerMode(_ mode: String?) {
        let prefs = readMutablePrefs()
        prefs["powerMode"] = mode ?? "fullPower"
        writePrefs(prefs)
        notify_post(settingsChangedNotification)
        notify_post(powerModeChangedNotification)
    }

    static func existingExecutablePath(rootFSPath: String, fallbacks: [String]) -> String? {
        let resolvedPath = jbRootPath(forRootFSPath: rootFSPath)
        if fileManager.isExecutableFile(atPath: resolvedPath) {
            return resolvedPath
        }
        for path in fallbacks where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    @discardableResult
    static func runAndWait(path: String?, arguments: [String]) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return arguments.withCStringArray { argv in
            var pid = pid_t(0)
            let result = posix_spawn(&pid, path, nil, nil, argv, nil)
            guard result == 0 else { return false }
            waitpid(pid, nil, 0)
            return true
        }
    }

    static func spawnDetached(path: String?, arguments: [String]) {
        guard let path, !path.isEmpty else { return }
        arguments.withCStringArray { argv in
            var pid = pid_t(0)
            if posix_spawn(&pid, path, nil, nil, argv, nil) == 0 {
                DispatchQueue.global(qos: .utility).async {
                    waitpid(pid, nil, 0)
                }
            }
        }
    }

    static func restartThermalmonitordNow() {
        if let toolPath, fileManager.isExecutableFile(atPath: toolPath), runAndWait(path: toolPath, arguments: ["CPUthermalTool", "restart-thermalmonitord"]) {
            return
        }
        _ = runAndWait(path: killallPath, arguments: ["killall", "-q", "thermalmonitord"])
    }

    static func restartThermalmonitordSoon() {
        if let toolPath, fileManager.isExecutableFile(atPath: toolPath) {
            spawnDetached(path: toolPath, arguments: ["CPUthermalTool", "restart-thermalmonitord-delayed"])
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
            restartThermalmonitordNow()
        }
    }
}

private extension Array where Element == String {
    func withCStringArray<Result>(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result) -> Result {
        let cStrings: [UnsafeMutablePointer<CChar>?] = map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var argv = cStrings
        argv.append(nil)
        return argv.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress)
        }
    }
}
