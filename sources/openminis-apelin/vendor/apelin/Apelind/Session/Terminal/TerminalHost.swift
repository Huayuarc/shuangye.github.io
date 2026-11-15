import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// The app's terminals: one `TerminalSession` per `ptyOpen`, its output
/// numbered into a `terminal` task (so a reattach replays the screen), its
/// I/O handed to the app on `ptyAttach{wantsDescriptor}`. M1 has no root
/// shell: the shell runs as mobile whenever the host is root.
actor TerminalHost {
    static let maximumSessions = 32
    private static let sizeRange = 1 ... 1000

    private let installRoot: String
    private let home: String
    private let scopes: FileScopes
    private let registry: TaskRegistry
    private let queue = DispatchQueue(label: "wiki.qaq.apelind.terminal")
    private var sessions: [String: TerminalSession] = [:]
    /// Shells spawned whose task is still being created, so not yet in `sessions`.
    private var opening = 0

    init(installRoot: String, home: String, scopes: FileScopes, registry: TaskRegistry) {
        self.installRoot = installRoot
        self.home = home
        self.scopes = scopes
        self.registry = registry
    }

    var count: Int {
        sessions.count
    }

    func open(_ request: PtyOpenRequest) async throws -> PtyOpenResponse {
        guard sessions.count + opening < Self.maximumSessions else {
            throw ApelinError(.unavailable, "too many terminals are open")
        }
        try Self.checkSize(columns: request.columns, rows: request.rows)
        var directory = home
        var projectDirectory: String?
        if let project = request.projectID {
            guard case let .directory(path) = try scopes.resolve(project, caller: .app) else {
                throw ApelinError(.badRequest, "projectID does not name a project")
            }
            directory = path
            projectDirectory = path
        }
        let launch = try Self.launch(
            installRoot: installRoot,
            home: home,
            directory: directory,
            project: projectDirectory,
            columns: request.columns,
            rows: request.rows,
        )
        let session: TerminalSession
        do {
            session = try TerminalSession.spawn(launch, queue: queue)
        } catch {
            throw ApelinError(.unavailable, "the terminal did not start: \(error)")
        }

        // Everything above is synchronous; this await is where other opens can
        // run, so the shell holds its place against the limit across it.
        opening += 1
        let handle = await registry.create(kind: .terminal, owner: nil)
        opening -= 1
        let id = handle.taskID.rawValue
        sessions[id] = session
        var started: [String: JSONValue] = [
            "pid": .number(Double(session.pid)),
            "shell": .string(launch.shell),
            "cwd": .string(launch.workingDirectory),
        ]
        if let credentials = ProcessCredentials(pid: session.pid) {
            started["uid"] = .number(Double(credentials.uid))
            started["gid"] = .number(Double(credentials.gid))
        }
        await registry.append(handle.taskID, kind: "started", payload: .object(started))

        // One consumer, so events are numbered in the order the bytes came.
        let registry = registry
        let taskID = handle.taskID
        let (events, sink) = AsyncStream<(kind: String, payload: JSONValue)>.makeStream()
        Task { [weak self] in
            var crash: Int32?
            for await event in events {
                await registry.append(taskID, kind: event.kind, payload: event.payload)
                if event.kind == "exit",
                   let signal = event.payload["signal"]?.doubleValue,
                   Self.crashSignals.contains(Int32(signal))
                {
                    crash = Int32(signal)
                }
            }
            // Closing a terminal ends it with HUP, TERM or KILL, and a shell
            // may exit with any status; a shell that crashed did not succeed.
            if let crash {
                await registry.finish(
                    taskID,
                    .failed,
                    message: "the shell crashed with signal \(crash) (\(String(cString: strsignal(crash))))",
                )
            } else {
                await registry.finish(taskID, .succeeded)
            }
            await self?.forget(id)
        }
        session.start(
            onOutput: { data in
                var payload: [String: JSONValue] = ["base64": .string(data.base64EncodedString())]
                if let text = String(data: data, encoding: .utf8) {
                    payload["text"] = .string(text)
                }
                sink.yield(("output", .object(payload)))
            },
            onExit: { status in
                var payload: [String: JSONValue] = [:]
                let signal = status & 0x7F
                if signal == 0 {
                    payload["status"] = .number(Double((status >> 8) & 0xFF))
                } else {
                    payload["signal"] = .number(Double(signal))
                }
                sink.yield(("exit", .object(payload)))
                sink.finish()
            },
        )
        if let input = request.initialInput, !input.isEmpty {
            // After the shell has had a moment to set the terminal up.
            queue.asyncAfter(deadline: .now() + 0.3) { session.write(Data(input.utf8)) }
        }
        return PtyOpenResponse(sessionID: id, task: handle)
    }

    /// A socket to the terminal for the app.
    func descriptor(for taskID: TaskID) throws -> OwnedDescriptor {
        guard let session = sessions[taskID.rawValue] else {
            throw ApelinError(.notFound, "no open terminal \(taskID)")
        }
        do {
            return try OwnedDescriptor(adopting: session.attachPeer())
        } catch {
            throw ApelinError(.internal, "\(error)")
        }
    }

    func resize(_ request: PtyResizeRequest) throws -> Acknowledged {
        guard let session = sessions[request.sessionID] else {
            throw ApelinError(.notFound, "no open terminal \(request.sessionID)")
        }
        try Self.checkSize(columns: request.columns, rows: request.rows)
        session.resize(columns: UInt16(request.columns), rows: UInt16(request.rows))
        return Acknowledged()
    }

    func close(_ request: PtyCloseRequest) throws -> Acknowledged {
        guard let session = sessions[request.sessionID] else {
            throw ApelinError(.notFound, "no open terminal \(request.sessionID)")
        }
        session.terminate()
        return Acknowledged()
    }

    func stopAll() {
        sessions.values.forEach { $0.terminate(grace: 0.5) }
    }

    private static func checkSize(columns: Int, rows: Int) throws {
        guard sizeRange.contains(columns), sizeRange.contains(rows) else {
            throw ApelinError(
                .badRequest,
                "columns and rows must each be \(sizeRange.lowerBound) to \(sizeRange.upperBound)",
            )
        }
    }

    private func forget(_ id: String) {
        sessions[id] = nil
    }

    /// Signals a shell dies of only when it crashed.
    static let crashSignals: Set<Int32> = [
        SIGSEGV,
        SIGBUS,
        SIGILL,
        SIGABRT,
        SIGTRAP,
        SIGFPE,
        SIGSYS,
    ]

    /// The shell, its arguments and the environment `login` would have set,
    /// with the development environment of `project` (a project folder, or
    /// nil for none) on top: its toolchain first on `PATH`, `SDKROOT` and
    /// `IPHONEOS_DEPLOYMENT_TARGET`, as the agent's shell_run gets them. A
    /// login shell's `/etc/profile` replaces `PATH`; the package's profile
    /// snippet puts the toolchain back from `APELIN_TOOLCHAIN_BIN`.
    static func launch(
        installRoot: String,
        home: String,
        directory: String,
        project: String? = nil,
        columns: Int,
        rows: Int,
    ) throws -> TerminalSession.Launch {
        let root = installRoot == "/" ? "" : installRoot
        let candidates = [
            "\(root)/usr/bin/bash",
            "\(root)/bin/bash",
            "\(root)/usr/bin/zsh",
            "\(root)/bin/zsh",
            "\(root)/bin/sh",
            "/bin/sh",
        ]
        guard let shell = candidates.first(where: { access($0, X_OK) == 0 }) else {
            throw ApelinError(.unavailable, "no shell is installed")
        }
        let name = (shell as NSString).lastPathComponent
        let arguments = name == "sh" ? ["-i"] : ["-il"]
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "Apelin",
            "HOME": home,
            "USER": "mobile",
            "LOGNAME": "mobile",
            "SHELL": shell,
            // iOS ships one locale, UTF-8, in /usr/share/locale; no LANG.
            // Under `LANG=en_US.UTF-8` setlocale fails and readline 8.2
            // dereferences the null it answers: bash crashed before its
            // first prompt and the terminal showed nothing.
            "LC_CTYPE": "UTF-8",
            // The agent's file tools refuse to lay out a bare repository,
            // and the user's git here takes none it finds by walking up
            // either: a pager or hook in one would run as mobile. Config
            // given through the environment is protected, as on the command
            // line, so a repository's own config cannot turn it back off.
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "safe.bareRepository",
            "GIT_CONFIG_VALUE_0": "explicit",
        ]
        let path = [
            "\(root)/usr/local/bin",
            "\(root)/usr/bin",
            "\(root)/bin",
            "\(root)/usr/sbin",
            "\(root)/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let development = DevelopmentEnvironment.prepared(home: home, projectDirectory: project)
        environment.merge(development.variables(basePath: path)) { _, prepared in prepared }
        return TerminalSession.Launch(
            shell: shell,
            arguments: arguments,
            environment: environment,
            identity: geteuid() == 0 ? .mobile : nil,
            workingDirectory: directory,
            fallbackDirectory: home,
            columns: UInt16(columns),
            rows: UInt16(rows),
        )
    }
}
