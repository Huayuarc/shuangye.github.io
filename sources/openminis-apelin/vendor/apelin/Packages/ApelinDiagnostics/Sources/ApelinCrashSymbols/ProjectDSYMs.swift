import Foundation

/// Where the symbolicator finds the DWARF for an image UUID.
///
/// Xrash's `DSYMStore` copies imported dSYMs into a store of its own. Apelin's
/// build keeps a dSYM beside every product it installs, so the lookup is
/// `ProjectDSYMs`, which reads those in place; `DSYMStore`, kept from the
/// port, still conforms, but only the tests construct one.
public protocol DSYMLookup: Sendable {
    /// The Mach-O holding DWARF for this image UUID, or nil.
    func url(forUUID uuid: String) -> URL?
    /// Changes whenever what `url(forUUID:)` can answer changes; the
    /// symbolicator drops its per-image cache when it does.
    var revision: Int { get }
}

/// The dSYMs a project's builds kept, indexed by image UUID, read where they
/// are. One entry per architecture slice that carries `__DWARF,__debug_line`;
/// a stripped binary with the same UUID never shadows its dSYM.
///
/// The index is built once, at init, from the directories given — the
/// project's build output folders, each holding `*.dSYM` bundles. A new build
/// makes a new index; nothing here watches the file system.
public struct ProjectDSYMs: DSYMLookup {
    public struct Entry: Hashable, Sendable {
        /// Uppercase, dashed: what reports are matched on.
        public var uuid: String
        public var arch: String
        /// The DWARF Mach-O inside the bundle.
        public var url: URL
    }

    public let entries: [Entry]
    public let revision: Int
    private let byUUID: [String: URL]

    /// `directories` are searched to `depth` levels for `.dSYM` bundles and
    /// bare DWARF Mach-O files. Bounded the way Xrash bounds an import.
    public init(directories: [URL], depth: Int = 4) {
        var entries = [Entry]()
        var byUUID = [String: URL]()
        for directory in directories {
            for candidate in DSYMStore.machOFiles(at: directory, depth: depth) {
                guard let handle = try? FileHandle(forReadingFrom: candidate),
                      let data = try? Data.mapping(handle),
                      let slices = try? MachOSlice.slices(of: data)
                else { continue }
                for slice in slices {
                    guard let uuid = slice.uuid?.uuidString,
                          slice.section(segment: "__DWARF", name: "__debug_line") != nil,
                          byUUID[uuid] == nil
                    else { continue }
                    byUUID[uuid] = candidate
                    entries.append(Entry(uuid: uuid, arch: slice.arch, url: candidate))
                }
            }
        }
        self.entries = entries
        self.byUUID = byUUID
        // The set of UUIDs is the whole of what this can answer.
        var hasher = Hasher()
        for uuid in byUUID.keys.sorted() {
            hasher.combine(uuid)
        }
        revision = hasher.finalize()
    }

    public func url(forUUID uuid: String) -> URL? {
        byUUID[uuid.uppercased()]
    }
}
