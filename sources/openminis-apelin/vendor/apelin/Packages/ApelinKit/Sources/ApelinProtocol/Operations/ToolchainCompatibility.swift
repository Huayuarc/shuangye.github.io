import ApelinCore
import Foundation

/// Versioned catalog metadata. It describes the compiler host, its inputs and
/// the evidence separately; none of these fields restricts SDK import.
/// The environment worker obtains the values from ApelinToolchain's single
/// release table, and records the same snapshot beside an installation.
public struct ToolchainCompatibility: Codable, Sendable, Equatable {
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
    /// Includes instructions in optional/guarded paths; informational only.
    public var staticInstructionFeatures: [String]
    public var systemSymbolSDK: String?
    public var systemSymbolCount: Int?
    public var notes: [String]

    public init(
        revision: Int = 1,
        sourceProductIDs: [String] = [],
        sourceSHA256s: [String: String]? = nil,
        hostArchitecture: String = "arm64",
        minimumHost: String = "16.0",
        cpuFeatures: [String] = ["FEAT_LRCPC"],
        requiredLibcxxSymbols: [String]? = nil,
        recommendedSDK: String,
        verifiedSDKs: [String] = [],
        recommendedSwiftSDK: String? = nil,
        verifiedSwiftSDKs: [String] = [],
        swiftMinimumHostBasis: String? = nil,
        swiftVerifiedHosts: [String] = [],
        staticInstructionFeatures: [String] = [],
        systemSymbolSDK: String? = nil,
        systemSymbolCount: Int? = nil,
        notes: [String] = [],
    ) {
        self.revision = revision
        self.sourceProductIDs = sourceProductIDs
        self.sourceSHA256s = sourceSHA256s
        self.hostArchitecture = hostArchitecture
        self.minimumHost = minimumHost
        self.cpuFeatures = cpuFeatures
        self.requiredLibcxxSymbols = requiredLibcxxSymbols
        self.recommendedSDK = recommendedSDK
        self.verifiedSDKs = verifiedSDKs
        self.recommendedSwiftSDK = recommendedSwiftSDK
        self.verifiedSwiftSDKs = verifiedSwiftSDKs
        self.swiftMinimumHostBasis = swiftMinimumHostBasis
        self.swiftVerifiedHosts = swiftVerifiedHosts
        self.staticInstructionFeatures = staticInstructionFeatures
        self.systemSymbolSDK = systemSymbolSDK
        self.systemSymbolCount = systemSymbolCount
        self.notes = notes
    }

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
            : "This toolchain requires C++ runtime symbols missing from this system: " + absent.joined(separator: ", ")
            + ". Choose an older toolchain."
    }

    public var unavailableReason: String? {
        #if os(iOS)
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return refusal(
                hostVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                hasFeature: HostCPU.has,
                hasLibcxxSymbol: HostCPU.hasLibcxxSymbol,
            )
        #else
            return nil
        #endif
    }
}
