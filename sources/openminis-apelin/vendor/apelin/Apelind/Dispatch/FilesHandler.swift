import ApelinProtocol

/// Scoped reads and the app's manual protected edit: the host's own work
/// (Session/Files). CallerPolicy already keeps workers away from the
/// protected edit; a grant scope is refused to them in FileScopes too.
enum FilesHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .fileRead:
            return await fileRead(request, host: host)
        case .protectedEditOpen:
            do {
                let open = try request.decode(ProtectedEditOpenRequest.self)
                let (response, descriptor) = try await host.editor.open(open)
                return (.success(request.requestID, response), [descriptor])
            } catch {
                return request.fail(error)
            }
        case .protectedEditCommit:
            return await request.serve(ProtectedEditCommitRequest.self) { commit in
                try await host.editor.commit(commit, descriptors: request.descriptors)
            }
        default:
            return request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a files operation"))
        }
    }

    private static func fileRead(_ request: HostRequest, host: SessionHost) async -> HostReply {
        do {
            let read = try request.decode(FileReadRequest.self)
            let descriptor: OwnedDescriptor
            let path: String
            switch try host.scopes.resolve(read.scopeID, caller: request.caller) {
            case let .directory(directory):
                (descriptor, path) = try FileScopes.open(read.relativePath, inside: directory)
            case let .grant(id):
                guard read.relativePath.isEmpty || read.relativePath == "." else {
                    throw ApelinError(.badRequest, "a grant scope is one file; leave relativePath empty")
                }
                let granted = try await host.editor.grantedPath(id)
                (descriptor, path) = try FileScopes.openRegular(granted, inside: granted)
            }
            let response = FileReadResponse(
                descriptor: DescriptorSlot(index: 0),
                version: FileScopes.version(of: descriptor.rawValue),
                path: path,
            )
            return (.success(request.requestID, response), [descriptor])
        } catch {
            return request.fail(error)
        }
    }
}
