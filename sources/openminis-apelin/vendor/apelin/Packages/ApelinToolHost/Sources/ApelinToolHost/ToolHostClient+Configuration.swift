import Foundation

public extension ToolHostClient {
    struct Configuration: Sendable {
        public var executable: String
        public var arguments: [String]
        /// The whole environment the extension gets; nothing is inherited.
        public var environment: [String: String]
        public var limits: ToolProtocolLimits
        public var host: ToolPeer
        /// When set, the authority on the extension's id and tools: a tool it
        /// does not list cannot be called, whatever `hello` claims.
        public var manifest: ToolManifest?
        /// Extensions run as mobile. A root caller is refused unless this is
        /// set, which only tests should do.
        public var allowRoot: Bool
        /// The identity a root caller (the session host) spawns the extension
        /// as: uid, gid and groups set before exec, then checked in the
        /// kernel. Nil spawns as the caller.
        public var runAs: ToolProcessIdentity?
        public var logHandler: (@Sendable (String) -> Void)?

        public init(
            executable: String,
            arguments: [String] = [],
            environment: [String: String] = Configuration.defaultEnvironment(),
            limits: ToolProtocolLimits = .init(),
            host: ToolPeer = ToolPeer(name: "apelin", version: "0"),
            manifest: ToolManifest? = nil,
            allowRoot: Bool = false,
            runAs: ToolProcessIdentity? = nil,
            logHandler: (@Sendable (String) -> Void)? = nil,
        ) {
            self.runAs = runAs
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.limits = limits
            self.host = host
            self.manifest = manifest
            self.allowRoot = allowRoot
            self.logHandler = logHandler
        }

        /// `PATH`, and `HOME` and `TMPDIR` from this process.
        public static func defaultEnvironment() -> [String: String] {
            var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            let current = ProcessInfo.processInfo.environment
            for key in ["HOME", "TMPDIR"] {
                environment[key] = current[key]
            }
            return environment
        }
    }
}
