import ApelinCore
import ApelinProtocol
import ApelinToolHost
import Darwin
import Foundation

// ApelinToolCore has its own JSONValue, ToolRisk and ToolDescriptor; this is
// the one file in apelind that imports it, so names are spelled with their
// module wherever both could be meant.

/// Agent tool extensions (Milestone 1 §6) run by the session host: the
/// manifest under `<install root>/usr/share/apelin/agent-tools/<id>/` is
/// validated (root-owned, inside the install root, executable checked again
/// right before the spawn), the extension is spawned as mobile with only the
/// environment given here, and its calls go through `ToolHostClient`.
///
/// A session belongs to the caller that opened it: the app's to the app, an
/// agent session's to that agent session alone.
///
/// Files cross a call both ways as host-made copies (`AttachmentCopies`):
/// the caller's descriptors are copied before the extension sees them, and
/// the extension's before the caller does.
actor ToolHostSessions {
    struct Session {
        let extensionID: String
        let owner: Caller
        let client: ToolHostClient
        let manifest: ToolManifest
    }

    static let maximumSessions = 16
    private static let maximumAttachmentFieldBytes = 255

    private let installRoot: String
    private let home: String
    private let copies: AttachmentCopies
    private var sessions: [String: Session] = [:]
    /// Extensions still starting, so not yet in `sessions`.
    private var opening = 0

    /// `attachments` is a root-only directory the relayed copies are made in
    /// (and unlinked from at once).
    init(installRoot: String, home: String, attachments: URL) {
        self.installRoot = installRoot
        self.home = home
        copies = AttachmentCopies(directory: attachments)
        copies.sweep()
    }

    var count: Int {
        sessions.count
    }

    func open(_ request: ToolHostOpenRequest, caller: Caller) async throws -> ToolHostOpenResponse {
        sweep()
        guard sessions.count + opening < Self.maximumSessions else {
            throw ApelinError(.unavailable, "too many tool extension sessions are open")
        }
        // Other opens can run while this one awaits the start; it holds its
        // place against the limit until it is in `sessions` or has failed.
        opening += 1
        defer { opening -= 1 }
        guard ToolManifestValidator.isValidID(request.id) else {
            throw ApelinError(.badRequest, "not an extension ID: \(request.id)")
        }
        let validated: ValidatedToolManifest
        do {
            validated = try ToolManifestValidator.validate(installRoot: installRoot, id: request.id)
        } catch let error as ToolManifestError {
            throw ApelinError(.denied, "the extension's manifest was refused: \(error.reason)")
        }
        let root = installRoot == "/" ? "" : installRoot
        let environment = [
            "HOME": home,
            "PATH": "\(root)/usr/bin:\(root)/bin:/usr/bin:/bin",
            "TMPDIR": home + "/tmp",
            "DISABLE_TWEAKS": "1",
        ]
        let identity: ToolProcessIdentity? = geteuid() == 0 ? .mobile : nil
        let client = ToolHostClient(
            validated: validated,
            environment: environment,
            host: ToolPeer(name: "apelin", version: Self.hostVersion),
            runAs: identity,
            logHandler: { line in NSLog("apelind-session: agent tool %@: %@", request.id, line) },
        )
        do {
            try await client.start()
        } catch {
            _ = await client.terminate()
            throw ApelinError(.unavailable, "the extension did not start: \(error)")
        }
        let id = UUID().uuidString.lowercased()
        sessions[id] = Session(
            extensionID: request.id,
            owner: caller,
            client: client,
            manifest: validated.manifest,
        )
        return ToolHostOpenResponse(sessionID: id, tools: validated.manifest.tools.map(Self.describe))
    }

    /// The reply's descriptors are the files the tool returned, in the order
    /// the response's `attachments` name them.
    func call(
        _ request: ToolHostCallRequest,
        descriptors: [OwnedDescriptor],
        caller: Caller,
    ) async throws -> (ToolHostCallResponse, [OwnedDescriptor]) {
        let session = try owned(request.sessionID, by: caller)
        guard session.manifest.tool(named: request.tool) != nil else {
            throw ApelinError(.badRequest, "\(session.extensionID) declares no tool \(request.tool)")
        }
        let arguments = try Self.convert(request.arguments)
        let limits = session.client.configuration.limits
        let maximumAttachments = min(limits.maxAttachmentsPerFrame, ToolHostCallRequest.maximumAttachments)
        let maximumBytes = min(limits.maxAttachmentBytes, ToolHostCallRequest.maximumAttachmentBytes)
        let outgoing = try outgoingFiles(
            request.attachments,
            descriptors: descriptors,
            maximumAttachments: maximumAttachments,
            maximumBytes: maximumBytes,
        )
        let outcome = await session.client.call(
            tool: request.tool,
            arguments: arguments,
            attachments: outgoing,
            timeout: request.timeoutSeconds,
        )
        switch outcome {
        case let .success(result):
            var attachments: [ToolHostAttachment] = []
            var returned: [OwnedDescriptor] = []
            for item in result.content {
                guard case let .file(file) = item else { continue }
                let copy: AttachmentCopies.Copy
                do {
                    copy = try copies.copy(file.descriptor, maximumBytes: maximumBytes)
                } catch let error as ApelinError {
                    return (
                        ToolHostCallResponse(
                            text: result.text,
                            error: .object([
                                "code": .string(ToolErrorCode.attachmentRejected.rawValue),
                                "message": .string(error.message),
                            ]),
                        ),
                        [],
                    )
                }
                attachments.append(
                    ToolHostAttachment(
                        descriptor: DescriptorSlot(index: returned.count),
                        name: file.name,
                        mimeType: file.mimeType,
                        byteCount: copy.byteCount,
                        sha256: copy.sha256,
                    ),
                )
                returned.append(copy.descriptor)
            }
            return (ToolHostCallResponse(text: result.text, attachments: attachments), returned)
        case let .failure(failure):
            return (
                ToolHostCallResponse(
                    text: "",
                    error: .object(["code": .string(failure.code.rawValue), "message": .string(failure.message)]),
                ),
                [],
            )
        }
    }

    func close(_ request: ToolHostCloseRequest, caller: Caller) async throws -> Acknowledged {
        let session = try owned(request.sessionID, by: caller)
        sessions[request.sessionID] = nil
        _ = await session.client.terminate()
        return Acknowledged()
    }

    /// An agent session ended: its extensions go with it.
    func closeAll(ownedBy caller: Caller) async {
        for (id, session) in sessions where session.owner == caller {
            sessions[id] = nil
            _ = await session.client.terminate()
        }
    }

    func stopAll() async {
        for session in sessions.values {
            _ = await session.client.terminate()
        }
        sessions.removeAll()
    }

    // MARK: Private

    private static let hostVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"

    /// The caller's files, each copied: a slot names one descriptor, once.
    private func outgoingFiles(
        _ slots: [ToolHostAttachmentSlot],
        descriptors: [OwnedDescriptor],
        maximumAttachments: Int,
        maximumBytes: Int,
    ) throws -> [ToolOutgoingAttachment] {
        guard slots.count <= maximumAttachments else {
            throw ApelinError(.badRequest, "a call carries at most \(maximumAttachments) attachments")
        }
        var used = Set<Int>()
        return try slots.map { slot in
            guard descriptors.indices.contains(slot.descriptor.index),
                  used.insert(slot.descriptor.index).inserted
            else {
                throw ApelinError(
                    .badRequest,
                    "attachment slot \(slot.descriptor.index) names a descriptor this request does not carry, or one another slot already names",
                )
            }
            for (field, value) in [("argument", slot.argument), ("mimeType", slot.mimeType), ("name", slot.name)] {
                guard let value else { continue }
                guard !value.isEmpty, value.utf8.count <= Self.maximumAttachmentFieldBytes,
                      !ApelinCore.CanonicalPath.containsNUL(value)
                else {
                    throw ApelinError(
                        .badRequest,
                        "an attachment's \(field) must be 1–\(Self.maximumAttachmentFieldBytes) bytes with no NUL",
                    )
                }
            }
            let copy = try copies.copy(descriptors[slot.descriptor.index].rawValue, maximumBytes: maximumBytes)
            do {
                return try ToolOutgoingAttachment(
                    duplicating: copy.descriptor.rawValue,
                    argument: slot.argument,
                    mimeType: slot.mimeType,
                    name: slot.name,
                )
            } catch {
                throw ApelinError(.unavailable, "the attachment copy cannot be passed on: \(error)")
            }
        }
    }

    private func owned(_ id: String, by caller: Caller) throws -> Session {
        sweep()
        guard let session = sessions[id], session.owner == caller else {
            throw ApelinError(.notFound, "no tool session \(id)")
        }
        return session
    }

    /// Drops sessions whose extension exited on its own.
    private func sweep() {
        sessions = sessions.filter { $0.value.client.exitStatus == nil }
    }

    private static func describe(_ tool: ApelinToolCore.ToolDescriptor) -> ApelinProtocol.ToolDescriptor {
        let risk: ApelinProtocol.ToolRisk = switch tool.risk {
        case .readOnly: .readOnly
        case .writeProject: .writesProject
        case .system: .system
        }
        let schema = (try? JSONCoding.decode(ApelinCore.JSONValue.self, from: JSONEncoder().encode(tool.parameters)))
            ?? .object([:])
        return ApelinProtocol.ToolDescriptor(name: tool.name, summary: tool.description, schema: schema, risk: risk)
    }

    private static func convert(_ value: ApelinCore.JSONValue) throws -> ApelinToolCore.JSONValue {
        do {
            return try JSONDecoder().decode(ApelinToolCore.JSONValue.self, from: JSONCoding.encode(value))
        } catch {
            throw ApelinError(.badRequest, "the arguments are not JSON the extension takes")
        }
    }
}
