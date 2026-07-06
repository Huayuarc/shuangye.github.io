import Foundation

@discardableResult
private func runExecutable(_ path: String?, arguments: [String]) -> Int32 {
    guard let path, !path.isEmpty else { return 127 }
    return arguments.withCStringArray { argv in
        var pid = pid_t(0)
        var status: Int32 = 0
        guard posix_spawn(&pid, path, nil, nil, argv, nil) == 0 else { return 126 }
        guard waitpid(pid, &status, 0) >= 0 else { return 125 }
        if (status & 0x7f) == 0 {
            return (status >> 8) & 0x000000ff
        }
        return status
    }
}

private func restartThermalmonitord() -> Int32 {
    runExecutable(CPUthermalShared.killallPath, arguments: ["killall", "-q", "thermalmonitord"])
}

private func restartThermalmonitordDelayed() -> Int32 {
    Thread.sleep(forTimeInterval: 2.0)
    return restartThermalmonitord()
}

private func reloadSpringBoard() -> Int32 {
    runExecutable(CPUthermalShared.sbreloadPath, arguments: ["sbreload"])
}

private func rebootUserspace() -> Int32 {
    runExecutable(CPUthermalShared.launchctlPath, arguments: ["launchctl", "reboot", "userspace"])
}

let command = CommandLine.arguments.dropFirst().first
let exitCode: Int32
switch command {
case "restart-thermalmonitord":
    exitCode = restartThermalmonitord()
case "restart-thermalmonitord-delayed":
    exitCode = restartThermalmonitordDelayed()
case "sbreload":
    exitCode = reloadSpringBoard()
case "userspace-reboot":
    exitCode = rebootUserspace()
default:
    print("CPUthermalTool commands:")
    print("  restart-thermalmonitord")
    print("  restart-thermalmonitord-delayed")
    print("  sbreload")
    print("  userspace-reboot")
    exitCode = 0
}

exit(exitCode)

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
