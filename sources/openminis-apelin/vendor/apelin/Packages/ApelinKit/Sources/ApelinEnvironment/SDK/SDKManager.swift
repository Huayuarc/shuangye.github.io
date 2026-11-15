import ApelinCore
import ApelinGit
import ApelinProtocol
import Darwin
import Foundation

/// sdkList, sdkImport and sdkRemove. An import is checked before the task is
/// accepted (`prepare`), then runs in its own staging folder (`run`): fetch
/// or copy, unpack, find the root, inspect, register.
public struct SDKManager: Sendable {
    public let layout: EnvironmentLayout
    public let store: SDKStore
    let projects: ProjectLocator
    var inspector = SDKInspector()
    var extractor = ArchiveExtractor()

    public init(layout: EnvironmentLayout) {
        self.layout = layout
        store = SDKStore(layout: layout)
        projects = ProjectLocator(layout: layout)
    }

    /// What an accepted import will read.
    public enum Prepared: Sendable {
        case repository(url: String, branch: String)
        case download(URL)
        case descriptor(OwnedDescriptor)
        case inboxFolder(URL, relative: String)
        case inboxArchive(URL, relative: String)
    }

    public func list(_ request: SDKListRequest) -> SDKListResponse {
        var response = SDKListResponse(sdks: store.list())
        if request.includeSources == true || request.readSources == true {
            response.sources = SDKSourceList.load(layout).statuses(read: request.readSources == true)
        }
        return response
    }

    public func remove(_ request: SDKRemoveRequest) throws -> Acknowledged {
        try store.remove(request.id, projects: projects)
        return Acknowledged()
    }

    /// Checks the request before the task is accepted, so a bad one is the
    /// reply rather than a failed task.
    public func prepare(_ request: SDKImportRequest, descriptors: [OwnedDescriptor]) throws -> Prepared {
        switch request.source {
        case let .repository(url, branch):
            try GitService.checkRemote(url: url, branch: branch)
            return .repository(url: url, branch: branch)
        case let .url(string):
            guard let url = URL(string: string), url.scheme?.lowercased() == "https", url.host != nil else {
                throw ApelinError(.badRequest, "Enter an HTTPS link to the SDK archive.")
            }
            return .download(url)
        case let .file(slot):
            guard descriptors.indices.contains(slot.index) else {
                throw ApelinError(.badRequest, "no descriptor at slot \(slot.index)")
            }
            return .descriptor(descriptors[slot.index])
        case let .inbox(path):
            return try inboxItem(path)
        }
    }

    /// Resolves a path in `inbox/` (relative to it, or absolute inside it)
    /// with realpath and a component compare.
    func inboxItem(_ path: String) throws -> Prepared {
        guard !CanonicalPath.containsNUL(path), !path.isEmpty else { throw ApelinError(.badRequest, "no inbox path") }
        guard let inbox = CanonicalPath.resolve(layout.inbox.path) else {
            throw ApelinError(.notFound, "there is no inbox folder in the data folder")
        }
        let candidate = path.hasPrefix("/") ? path : layout.inbox.appendingPathComponent(path).path
        guard let resolved = CanonicalPath.resolve(candidate) else {
            throw ApelinError(.notFound, "\(path) is not in the inbox")
        }
        guard CanonicalPath.isCanonical(resolved, inside: inbox), resolved != inbox else {
            throw ApelinError(.denied, "\(path) is not inside the inbox")
        }
        let relative = CanonicalPath.components(resolved)
            .dropFirst(CanonicalPath.components(inbox).count)
            .joined(separator: "/")
        var metadata = stat()
        guard stat(resolved, &metadata) == 0 else { throw ApelinError(.notFound, "\(path) is not in the inbox") }
        let url = URL(fileURLWithPath: resolved)
        switch metadata.st_mode & S_IFMT {
        case S_IFDIR: return .inboxFolder(url, relative: relative)
        case S_IFREG: return .inboxArchive(url, relative: relative)
        default: throw ApelinError(.badRequest, "\(path) is neither a folder nor an archive")
        }
    }

    /// Runs an accepted import in `staging` (this task's own, empty).
    public func run(
        _ prepared: Prepared,
        staging: URL,
        hasSwiftToolchain: Bool,
        reporter: TaskReporter,
    ) async throws -> SDKRecord {
        let unpacked = staging.appendingPathComponent("tree", isDirectory: true)
        guard mkdir(unpacked.path, 0o755) == 0 else { throw ArchiveExtractor.posix("make the staging tree") }
        let origin: String

        switch prepared {
        case let .repository(url, branch):
            reporter.stage("fetching")
            let throttle = ProgressThrottle()
            let result: GitCloneResult
            do {
                result = try GitClone.shallow(url: url, branch: branch, into: unpacked) { progress in
                    if throttle.shouldEmit() {
                        reporter.progress(
                            "fetching",
                            completed: Int64(progress.receivedBytes),
                            detail: "\(progress.indexedObjects)/\(progress.totalObjects) objects",
                        )
                    }
                    return !reporter.isCancelled
                }
            } catch {
                throw GitService.apelinError(error)
            }
            // Pinned by commit, not by the movable branch name.
            try FileManager.default.removeItem(at: unpacked.appendingPathComponent(".git"))
            origin = "repository \(url)#\(branch)@\(result.commit)"
        case let .download(url):
            reporter.stage("fetching")
            let archive = try await download(url, into: staging, reporter: reporter)
            reporter.stage("extracting")
            try extractor.extract(.path(archive.path), into: unpacked, reporter: reporter)
            try? FileManager.default.removeItem(at: archive)
            // No user, password, query or fragment, where a token rides: the
            // origin is in every sdkList reply and every .apesdk.
            var shown = URLComponents(url: url, resolvingAgainstBaseURL: false)
            shown?.user = nil
            shown?.password = nil
            shown?.query = nil
            shown?.fragment = nil
            origin = "url \(shown?.string ?? url.host ?? "")"
        case let .descriptor(descriptor):
            reporter.stage("extracting")
            try extractor.extract(.descriptor(descriptor.rawValue), into: unpacked, reporter: reporter)
            origin = "file"
        case let .inboxArchive(url, relative):
            reporter.stage("extracting")
            try extractor.extract(.path(url.path), into: unpacked, reporter: reporter)
            origin = "inbox \(relative)"
        case let .inboxFolder(url, relative):
            reporter.stage("extracting")
            // A copy, links kept as links: what is inspected is what is
            // registered, whatever happens to the inbox meanwhile.
            let copy = unpacked.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            do {
                try FileManager.default.copyItem(at: url, to: copy)
            } catch {
                throw ApelinError(.internal, "cannot copy \(relative) out of the inbox: \(error)")
            }
            origin = "inbox \(relative)"
        }
        try reporter.checkCancelled()

        reporter.stage("inspecting")
        let root = try inspector.locateRoot(in: unpacked)
        var inspection = try inspector.inspect(root, reporter: reporter)
        if inspection.identity.swiftCompilerVersion != nil, !hasSwiftToolchain {
            inspection.warnings.append(
                "no registered toolchain has Swift; Swift projects cannot build against this SDK yet",
            )
        }
        inspection.warnings.forEach(reporter.warning)
        try reporter.checkCancelled()

        reporter.stage("registering")
        return try store.register(root: root, inspection: inspection, origin: origin)
    }

    private func download(_ url: URL, into staging: URL, reporter: TaskReporter) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw ApelinError(
                .unavailable,
                "Unable to download the SDK from \(url.host ?? "the server"). Check the link and try again.",
            )
        }
        try reporter.checkCancelled()
        let destination = staging.appendingPathComponent("download")
        try FileManager.default.moveItem(at: temporary, to: destination)
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
        reporter.progress("fetching", completed: size ?? 0, total: size, detail: url.lastPathComponent)
        return destination
    }
}
