import Darwin
import Foundation

/// The installation catalog's data, also saved with each prepared toolchain.
/// SDK import never consults this: these are compiler/SDK pairings, not rules
/// about which SDK may be stored on a device.
public struct ReleaseCompatibility: Codable, Sendable, Equatable {
    public var revision: Int
    public var sourceProductIDs: [String]
    public var sourceSHA256s: [String: String]?
    public var hostArchitecture: String
    public var minimumHost: String
    public var cpuFeatures: [String]
    public var requiredLibcxxSymbols: [String]?
    public var recommendedSDK: String
    public var verifiedSDKs: [String]
    public var recommendedSwiftSDK: String?
    public var verifiedSwiftSDKs: [String]
    public var swiftMinimumHostBasis: String?
    public var swiftVerifiedHosts: [String]
    /// Selected optional ISA features found across the shipped host images. This includes optional or
    /// guarded code paths; it must not replace per-capability requirements.
    public var staticInstructionFeatures: [String]
    /// SDK declarations checked statically, not a run on that OS version.
    public var systemSymbolSDK: String?
    public var systemSymbolCount: Int?
    public var notes: [String]

    public func refusal(
        hostVersion: String,
        hasFeature: (String) -> Bool,
        hasLibcxxSymbol: (String) -> Bool = { _ in false },
    ) -> String? {
        if hostVersion.compare(minimumHost, options: .numeric) == .orderedAscending {
            return "This toolchain requires iOS \(minimumHost) or later."
        }
        let missing = cpuFeatures.filter { !hasFeature($0) }
        if !missing.isEmpty {
            return "This toolchain requires CPU features this device lacks: " + missing.joined(separator: ", ") + "."
        }
        let absent = (requiredLibcxxSymbols ?? []).filter { !hasLibcxxSymbol($0) }
        return absent.isEmpty
            ? nil
            : "This toolchain requires a newer C++ runtime than this system provides. Choose an older toolchain."
    }

    public var hostRefusal: String? {
        #if os(iOS)
            return refusal(hostVersion: hostOSVersion, hasFeature: hostHasCPUFeature, hasLibcxxSymbol: { name in
                guard !name.utf8.contains(0), let image = dlopen("/usr/lib/libc++.1.dylib", RTLD_LAZY | RTLD_LOCAL) else {
                    return false
                }
                defer { dlclose(image) }
                return dlsym(image, name) != nil
            })
        #else
            return nil
        #endif
    }
}

#if os(iOS)
    /// The running iOS, `major.minor.patch`, as the host requirements compare it.
    var hostOSVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    /// Whether the kernel reports `feature` (a name such as `FEAT_LRCPC`) on this device.
    func hostHasCPUFeature(_ feature: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm." + feature, &value, &size, nil, 0) == 0 && value != 0
    }
#endif

public extension CommandLineToolsRelease {
    var compatibility: ReleaseCompatibility {
        ReleaseCompatibility(
            revision: 1,
            sourceProductIDs: sourceProductIDs,
            sourceSHA256s: sources,
            hostArchitecture: "arm64",
            minimumHost: ToolchainSetup.defaultMinimumOS,
            cpuFeatures: ["FEAT_LRCPC"],
            requiredLibcxxSymbols: requiredLibcxxSymbols,
            recommendedSDK: recommendedSDK,
            verifiedSDKs: verifiedSDKs,
            recommendedSwiftSDK: swift ? recommendedSDK : nil,
            verifiedSwiftSDKs: verifiedSwiftSDKs,
            swiftMinimumHostBasis: swiftSupport?.minimumHostBasis,
            swiftVerifiedHosts: swiftSupport?.verifiedHosts ?? [],
            staticInstructionFeatures: staticInstructionFeatures,
            systemSymbolSDK: systemSymbolSDK,
            systemSymbolCount: systemSymbolCount,
            notes: [
                "SDK versions describe build inputs, not the device's OS or the output's deployment target.",
                "The base component supports C, C++ and Objective-C without clang modules on an LRCPC CPU.",
                "Clang modules and Swift have separate CPU requirements; the complete image may contain guarded instructions.",
                "Unreviewed Swift components are not offered even when their instructions fit the CPU.",
            ],
        )
    }
}

/// Explanatory groups covering devices supported by iOS/iPadOS 16 and later.
/// Only the features used by our compatibility rules are listed. A device is
/// always evaluated using its kernel feature flags, never its model name.
public struct ToolchainCPUProfile: Codable, Sendable, Equatable {
    public let chips: [String]
    public let cpuFeatures: [String]
    public let llvmCPU: String
}

public extension CommandLineToolsSupport {
    static let cpuProfiles: [ToolchainCPUProfile] = [
        .init(chips: ["A9", "A9X"], cpuFeatures: [], llvmCPU: "apple-a9"),
        .init(chips: ["A10", "A10X"], cpuFeatures: [], llvmCPU: "apple-a10"),
        .init(chips: ["A11"], cpuFeatures: [], llvmCPU: "apple-a11"),
        .init(chips: ["A12", "A12X", "A12Z"], cpuFeatures: ["FEAT_LRCPC"], llvmCPU: "apple-a12"),
        .init(chips: ["A13 and later"], cpuFeatures: ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"], llvmCPU: "apple-a13"),
        .init(chips: ["M1 and later"], cpuFeatures: ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"], llvmCPU: "apple-m1"),
    ]
}
