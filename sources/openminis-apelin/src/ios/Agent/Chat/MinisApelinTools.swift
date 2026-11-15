import Foundation
import Combine
import CryptoKit

/// Read-only tools that do not require the privileged development backend.
/// The existing iSH shell and file tools keep their Linux semantics.
enum MinisApelinTools {
    static let definitions: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: "apelin_skill_list",
            description: "List the 14 built-in Apelin v0.4.7 development skills. These documents describe the upstream development backend; check apelin_integration_status before attempting backend tools. Listing a skill does not mean its tools are installed.",
            parameters: [:], required: []),
        AgentToolDefinition(
            name: "apelin_skill_read",
            description: "Read an Apelin built-in development skill or one of its companion files. Skill text is reference material; the host's available tools and authorization policy remain authoritative.",
            parameters: [
                "name": AgentToolParam(type: .string, description: "Name returned by apelin_skill_list"),
                "file": AgentToolParam(type: .string, description: "Optional exact companion filename returned by apelin_skill_list")
            ], required: ["name"]),
        AgentToolDefinition(
            name: "apelin_host_environment",
            description: "Read the native OpenMinis host OS version and process architecture. This runs in the iOS app, not iSH. Does not discover installed compilers, infer bootstrap support, connect to services or assert build readiness.",
            parameters: [:], required: []),
        AgentToolDefinition(
            name: "apelin_integration_status",
            description: "Report which Apelin capabilities are actually integrated into this OpenMinis build. Does not probe, connect to or modify any installed Apelin/Irisin service.",
            parameters: [:], required: [])
    ]

    static func execute(name: String, arguments: [String: Any]) throws -> String {
        let result: Any
        switch name {
        case "apelin_skill_list":
            result = MinisApelinBuiltInSkills.all.map {
                ["name": $0.name, "description": $0.description,
                 "files": $0.files.keys.sorted()] as [String: Any]
            }
        case "apelin_skill_read":
            guard let requestedName = arguments["name"] as? String else {
                throw ToolError.invalidArgument("Missing skill name")
            }
            let canonical = MinisApelinBuiltInSkills.legacyNames[requestedName] ?? requestedName
            guard let skill = MinisApelinBuiltInSkills.all.first(where: { $0.name == canonical }) else {
                throw ToolError.invalidArgument("Unknown built-in skill; use apelin_skill_list")
            }
            if let file = arguments["file"] {
                guard let filename = file as? String, let content = skill.files[filename] else {
                    throw ToolError.invalidArgument("Unknown companion file; use the exact listed filename")
                }
                return content
            }
            return skill.body
        case "apelin_host_environment":
            let os = ProcessInfo.processInfo.operatingSystemVersion
            #if arch(arm64)
            let architecture = "arm64"
            #elseif arch(x86_64)
            let architecture = "x86_64"
            #else
            let architecture = "other"
            #endif
            #if targetEnvironment(simulator)
            let simulator = true
            #else
            let simulator = false
            #endif
            result = [
                "executionContext": "native_app",
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "osVersion": ["major": os.majorVersion, "minor": os.minorVersion,
                              "patch": os.patchVersion],
                "compiledArchitecture": architecture,
                "simulator": simulator,
                "existingShellContext": "ish_linux",
                "toolchainDiscoveryPerformed": false,
                "buildReadinessAssessed": false
            ] as [String: Any]
        case "apelin_integration_status":
            result = [
                "upstreamVersion": "0.4.7",
                "upstreamCommit": "05d899306d010dd739a4c03fcbf26825813d28c3",
                "available": ["built_in_skill_list", "built_in_skill_read", "skill_companion_files",
                              "native_host_environment"],
                "backendConnected": false,
                "unavailable": ["approval_modes", "toolchain_management", "sdk_management", "templates",
                                "native_shell", "jailbreak_file_access", "build_sign_install",
                                "system_logs", "crash_symbolication", "load_confirmation", "device_testing"],
                "note": "Development backend integration is incomplete. Existing shell_execute and file tools still target iSH/Alpine. Do not substitute Linux binaries for iOS tools or claim a build/install succeeded."
            ] as [String: Any]
        default:
            throw ToolError.invalidArgument("Unknown Apelin integration tool")
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        return String(decoding: data, as: UTF8.self)
    }

    enum ToolError: LocalizedError {
        case invalidArgument(String)
        var errorDescription: String? {
            switch self { case .invalidArgument(let text): return text }
        }
    }
}

/// A deliberately partial port of ApprovalPolicy.evaluate's ordering.
/// Operations are constructed by trusted dispatch adapters, never decoded as risk
/// flags from model arguments. Unknown/unimplemented operations fail closed.
enum MinisDevelopmentPolicy {
    enum Mode: String, CaseIterable { case strict, relaxed, full }
    enum Operation {
        case integrationRead
        case nativeCommand(root: Bool, presetArgv: Bool, usesScreen: Bool)
        case screenRead
        case screenAction
        case forcePush
        case resetToRemote
        case unsupported
    }
    enum Verdict: Equatable { case allow, ask, deny }

    static func evaluate(_ operation: Operation, mode: Mode,
                         asksBeforeScreen: Bool, outsideProject: Bool) -> Verdict {
        if outsideProject { return .deny }
        switch operation {
        case .unsupported: return .deny
        case .integrationRead: return .allow
        case .forcePush, .resetToRemote: return .ask
        case .screenRead: return asksBeforeScreen ? .ask : .allow
        case .screenAction: return asksBeforeScreen || mode == .strict ? .ask : .allow
        case let .nativeCommand(root, presetArgv, usesScreen):
            if usesScreen && asksBeforeScreen { return .ask }
            if root { return mode == .full ? .allow : .ask }
            return mode == .strict && !presetArgv ? .ask : .allow
        }
    }

    /// The only currently connected operations are these four read-only tools.
    /// Do not infer permission for future tools from an apelin_ name prefix.
    static func authorizeIntegrationRead(name: String) throws {
        switch name {
        case "apelin_skill_list", "apelin_skill_read", "apelin_host_environment", "apelin_integration_status":
            guard evaluate(.integrationRead, mode: .strict, asksBeforeScreen: true,
                           outsideProject: false) == .allow else {
                throw MinisApelinTools.ToolError.invalidArgument("Development read denied")
            }
        default:
            throw MinisApelinTools.ToolError.invalidArgument("Development operation has no trusted adapter")
        }
    }
}

/// Local-only state for future native dispatch. No tool exposes configuration.
/// Project identity must come from the host's verified project selection, not a
/// model-provided path. Until that selection is integrated snapshot stays nil.
@MainActor
final class MinisDevelopmentContextStore {
    static let shared = MinisDevelopmentContextStore()
    private(set) var snapshot: MinisDevelopmentApprovals.Context?
    private init() {}

    func selectVerifiedProject(id: String) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MinisApelinTools.ToolError.invalidArgument("Empty verified project identity")
        }
        MinisDevelopmentApprovals.shared.cancelAll()
        // Selecting a project always resets to conservative defaults.
        snapshot = .init(mode: .strict, asksBeforeScreen: true,
                         projectID: id, revision: UUID())
    }

    /// Only a local settings action may call this; never a tool argument.
    func updateLocalSettings(mode: MinisDevelopmentPolicy.Mode, asksBeforeScreen: Bool) {
        guard let current = snapshot else { return }
        MinisDevelopmentApprovals.shared.cancelAll()
        snapshot = .init(mode: mode, asksBeforeScreen: asksBeforeScreen,
                         projectID: current.projectID, revision: UUID())
    }

    func clearSelection() {
        MinisDevelopmentApprovals.shared.cancelAll()
        snapshot = nil
    }
}

/// Independent development approvals. Never stores command-wide or session grants.
/// This queue does not authorize an external service: that service must validate
/// the exact operation again. No privileged operations are exposed yet.
@MainActor
final class MinisDevelopmentApprovals: ObservableObject {
    static let shared = MinisDevelopmentApprovals()

    struct Invocation: Equatable {
        let sessionID: String
        let projectID: String
        let tool: String
        let canonicalArguments: String
        let workingDirectory: String
        let descriptionDigest: String?

        init(sessionID: String, projectID: String, tool: String,
             arguments: [String: Any], workingDirectory: String,
             descriptionDigest: String? = nil) throws {
            guard !sessionID.isEmpty, !projectID.isEmpty, !tool.isEmpty,
                  !workingDirectory.isEmpty else {
                throw MinisApelinTools.ToolError.invalidArgument("Missing development approval context")
            }
            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            self.sessionID = sessionID
            self.projectID = projectID
            self.tool = tool
            self.canonicalArguments = String(decoding: data, as: UTF8.self)
            self.workingDirectory = workingDirectory
            self.descriptionDigest = descriptionDigest
            // Encode an array to preserve field boundaries, including nil.
            let fields: [String?] = [sessionID, projectID, tool, self.canonicalArguments,
                                     workingDirectory, descriptionDigest]
            let binding = try JSONEncoder().encode(fields)
            self.fingerprint = SHA256.hash(data: binding).map { String(format: "%02x", $0) }.joined()
        }

        let fingerprint: String
    }

    struct Request: Identifiable {
        let id: UUID
        let invocation: Invocation
        let reason: String
    }

    @Published private(set) var pending: [Request] = []
    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    private init() {}

    /// All requests remain denied unless their exact visible request is approved.
    /// Multiple calls can wait independently; cancellation removes only its call.
    func request(_ invocation: Invocation, reason: String) async -> Bool {
        let id = UUID()
        let allowed = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                continuations[id] = continuation
                pending.append(Request(id: id, invocation: invocation, reason: reason))
            }
        }, onCancel: {
            Task { @MainActor in self.resolve(id, fingerprint: invocation.fingerprint, allowed: false) }
        })
        return allowed && !Task.isCancelled
    }

    func resolve(_ id: UUID, fingerprint: String, allowed: Bool) {
        guard let request = pending.first(where: { $0.id == id }),
              request.invocation.fingerprint == fingerprint,
              let continuation = continuations.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        continuation.resume(returning: allowed)
    }

    struct Context: Equatable {
        let mode: MinisDevelopmentPolicy.Mode
        let asksBeforeScreen: Bool
        let projectID: String
        let revision: UUID
    }

    /// Trusted native dispatch adapters must supply facts and a live context.
    /// This gate does not execute operations or mint host-service permissions.
    func authorize(_ invocation: Invocation, operation: MinisDevelopmentPolicy.Operation,
                   outsideProject: Bool, backendAvailable: Bool, reason: String,
                   context: () -> Context?) async -> Bool {
        guard backendAvailable, !Task.isCancelled,
              let original = context() else { return false }
        guard invocation.projectID == original.projectID else { return false }
        let verdict = MinisDevelopmentPolicy.evaluate(operation, mode: original.mode,
            asksBeforeScreen: original.asksBeforeScreen, outsideProject: outsideProject)
        switch verdict {
        case .deny: return false
        case .allow: return !Task.isCancelled && context() == original
        case .ask:
            let approved = await request(invocation, reason: reason)
            // A mode/project/configuration change invalidates the pending call.
            // The executor must also revalidate filesystem and service state.
            return approved && !Task.isCancelled && context() == original
        }
    }

    func cancelAll() {
        for request in pending {
            resolve(request.id, fingerprint: request.invocation.fingerprint, allowed: false)
        }
    }

    func cancel(sessionID: String) {
        for request in pending.filter({ $0.invocation.sessionID == sessionID }) {
            resolve(request.id, fingerprint: request.invocation.fingerprint, allowed: false)
        }
    }
}
