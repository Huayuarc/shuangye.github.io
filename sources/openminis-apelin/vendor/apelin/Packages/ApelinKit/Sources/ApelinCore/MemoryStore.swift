import Darwin
import Foundation

public struct MemoryRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    /// Nil for preferences shared by all chats; otherwise the stable project identity.
    public let projectID: String?

    public init(id: String = UUID().uuidString.lowercased(), title: String, body: String, projectID: String? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.projectID = projectID
    }
}

public struct MemorySnapshot: Codable, Equatable, Sendable {
    public let revision: String
    public let records: [MemoryRecord]

    public func forProject(_ projectID: String) -> MemorySnapshot {
        MemorySnapshot(revision: revision, records: records.filter { $0.projectID == nil || $0.projectID == projectID })
    }
}

public enum MemoryStoreError: Error, Equatable {
    case changed
    case invalidContent
    case full
    case unsafeFile
}

/// One disk authority shared by the app and every agent process. No cached
/// snapshot is ever written back: every mutation locks, rereads and compares
/// the supplied revision, including creations after a user deleted a record.
public struct MemoryStore: Sendable {
    public static let maximumRecords = 64
    public static let maximumContentBytes = 32768
    private static let maximumFileBytes = 262_144
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func read() throws -> MemorySnapshot {
        try locked { directory in try read(in: directory) }
    }

    @discardableResult
    public func save(
        _ record: MemoryRecord,
        replacing existingID: String? = nil,
        revision: String,
    ) throws -> MemorySnapshot {
        try locked { directory in
            var snapshot = try read(in: directory)
            guard snapshot.revision == revision else { throw MemoryStoreError.changed }
            var records = snapshot.records
            let normalized = MemoryRecord(
                id: record.id,
                title: record.title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: record.body.trimmingCharacters(in: .whitespacesAndNewlines),
                projectID: record.projectID,
            )
            if let existingID {
                guard existingID == record.id, let index = records.firstIndex(where: { $0.id == existingID }),
                      records[index].projectID == record.projectID else { throw MemoryStoreError.changed }
                records[index] = normalized
            } else {
                guard !records.contains(where: { $0.id == record.id }) else { throw MemoryStoreError.changed }
                records.append(normalized)
            }
            try validate(records)
            snapshot = MemorySnapshot(revision: UUID().uuidString.lowercased(), records: records)
            try write(snapshot, in: directory)
            return snapshot
        }
    }

    @discardableResult
    public func delete(id: String, revision: String) throws -> MemorySnapshot {
        try locked { directory in
            let previous = try read(in: directory)
            guard previous.revision == revision, previous.records.contains(where: { $0.id == id }) else {
                throw MemoryStoreError.changed
            }
            let snapshot = MemorySnapshot(
                revision: UUID().uuidString.lowercased(),
                records: previous.records.filter { $0.id != id },
            )
            try write(snapshot, in: directory)
            return snapshot
        }
    }

    private func validate(_ records: [MemoryRecord]) throws {
        guard records.count <= Self.maximumRecords,
              records.reduce(0, { $0 + $1.title.utf8.count + $1.body.utf8.count }) <= Self.maximumContentBytes
        else {
            throw MemoryStoreError.full
        }
        guard Set(records.map(\.id)).count == records.count else { throw MemoryStoreError.invalidContent }
        for record in records {
            guard UUID(uuidString: record.id) != nil,
                  !record.title.isEmpty,
                  !record.body.isEmpty,
                  !record.title.contains(where: \.isNewline),
                  !record.title.utf8.contains(0), !record.body.utf8.contains(0),
                  record.projectID.map({ !$0.isEmpty && $0.utf8.count <= 255 && !$0.utf8.contains(0) }) ?? true
            else {
                throw MemoryStoreError.invalidContent
            }
        }
    }

    private func locked<T>(_ operation: (Int32) throws -> T) throws -> T {
        guard let canonical = CanonicalPath.resolve(root.path) else { throw MemoryStoreError.unsafeFile }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw MemoryStoreError.unsafeFile }
        let directory = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw posixError() }
        defer { close(directory) }
        var opened = stat()
        guard fstat(directory, &opened) == 0, info.st_dev == opened.st_dev, info.st_ino == opened.st_ino else {
            throw MemoryStoreError.unsafeFile
        }
        let lock = openat(directory, "memories.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw posixError() }
        defer { close(lock) }
        try checkRegular(lock)
        guard flock(lock, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(lock, LOCK_UN) }
        return try operation(directory)
    }

    private func read(in directory: Int32) throws -> MemorySnapshot {
        let descriptor = openat(directory, "memories.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT {
                return MemorySnapshot(revision: "empty", records: [])
            }
            throw posixError()
        }
        defer { close(descriptor) }
        try checkRegular(descriptor)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes else { throw MemoryStoreError.full }
        let snapshot = try JSONDecoder().decode(MemorySnapshot.self, from: data)
        guard UUID(uuidString: snapshot.revision) != nil else { throw MemoryStoreError.invalidContent }
        try validate(snapshot.records)
        return snapshot
    }

    private func write(_ snapshot: MemorySnapshot, in directory: Int32) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumFileBytes else { throw MemoryStoreError.full }
        let temporary = ".memories-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0, renameat(directory, temporary, directory, "memories.json") == 0, fsync(directory) == 0 else { throw posixError() }
    }

    private func checkRegular(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw MemoryStoreError.unsafeFile }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
