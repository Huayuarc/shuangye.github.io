import ApelinCore
import ApelinProtocol
import Foundation

/// What an agent may set up on the device — a toolchain from Apple's
/// catalog (`apelin_toolchain_setup`), an SDK from an SDK source (`apelin_sdk_import`) —
/// decided by the host from the request and the session's own approvals,
/// never from what the agent says it asked.
///
/// In every mode a setup names the catalog product the user was shown and
/// carries no package file, and an import is one branch of an HTTPS
/// repository with no user, password, query or fragment and no file: an
/// agent never installs from a file, a link or the inbox. Under Confirm each
/// one also spends an approval the app gave this session for exactly it
/// (`covers`), so one approval sets up one thing once, and nothing is ever
/// granted for the session. Both run as the app's do, through
/// apelin-environment and, for a toolchain, the host's install bridge; the
/// task an agent started is ended, not resumed, if the host stops
/// (TaskResume), and a setup's job record stays for the next setup of the
/// same release to pick up.
enum AgentEnvironmentRules {
    static let setupTool = AgentToolName.toolchainSetup.rawValue
    static let importTool = AgentToolName.sdkImport.rawValue

    static func refusal(_ setup: ToolchainSetupRequest, descriptorCount: Int) -> ApelinError? {
        guard descriptorCount == 0, case let .appleCatalog(productID?) = setup.source, !productID.isEmpty else {
            return ApelinError(.denied, "an agent sets up a toolchain only from Apple's catalog, naming its product")
        }
        return nil
    }

    static func refusal(_ request: SDKImportRequest, descriptorCount: Int) -> ApelinError? {
        guard descriptorCount == 0, case let .repository(url, branch) = request.source, !branch.isEmpty else {
            return ApelinError(.denied, "an agent imports an SDK only from an SDK source's repository")
        }
        guard let parts = URLComponents(string: url), parts.scheme?.lowercased() == "https",
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil
        else {
            return ApelinError(.denied, "an SDK source is an HTTPS address with no credentials, query or fragment")
        }
        return nil
    }

    /// Whether `asked`, the payload of one of the session's own
    /// `approvalRequested` events, approves exactly this setup: the product
    /// and the components the card named.
    static func covers(_ setup: ToolchainSetupRequest, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == setupTool, case let .appleCatalog(productID?) = setup.source,
              let detail = asked["detail"]?["toolchainSetup"],
              detail["productID"]?.stringValue == productID,
              case let .array(components)? = detail["components"]
        else { return false }
        return Set(components.compactMap(\.stringValue)) == Set(setup.components.map(\.rawValue))
    }

    /// Whether `asked` approves exactly this import: the repository and the
    /// branch the card named.
    static func covers(_ request: SDKImportRequest, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == importTool, case let .repository(url, branch) = request.source,
              let detail = asked["detail"]?["sdkImport"]
        else { return false }
        return detail["url"]?.stringValue == url && detail["branch"]?.stringValue == branch
    }

    /// The host's check of an agent's `toolchainSetup` or `sdkImport`; any
    /// other operation passes.
    static func authorize(
        _ request: WireRequest,
        descriptorCount: Int,
        entry: AgentSessionTable.Entry?,
        registry: TaskRegistry,
    ) async throws {
        guard let entry else { throw ApelinError(.denied, "no agent session for this worker") }
        let covers: (JSONValue) -> Bool
        switch request.operation {
        case .toolchainSetup:
            let setup = try request.decode(ToolchainSetupRequest.self)
            if let refusal = refusal(setup, descriptorCount: descriptorCount) {
                throw refusal
            }
            covers = { Self.covers(setup, asked: $0) }
        case .sdkImport:
            let sdkImport = try request.decode(SDKImportRequest.self)
            if let refusal = refusal(sdkImport, descriptorCount: descriptorCount) {
                throw refusal
            }
            covers = { Self.covers(sdkImport, asked: $0) }
        default:
            return
        }
        guard entry.mode.asks else { return }
        guard await AgentApprovals.spend(entry: entry, registry: registry, covers: covers) else {
            throw ApelinError(
                .denied,
                "approval required: the user has not approved this \(request.operation == .sdkImport ? "SDK import" : "toolchain setup")",
            )
        }
    }
}
