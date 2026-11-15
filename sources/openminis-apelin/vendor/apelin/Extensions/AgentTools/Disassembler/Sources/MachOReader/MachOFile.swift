// MachOReader — a minimal, self-contained Mach-O reader for the
// disassembler extension: thin and fat files, 64-bit slices, segments,
// sections, LC_SYMTAB and LC_UUID. MIT, see the repository LICENSE.

import Darwin
import Foundation

public enum MachOError: Error, CustomStringConvertible {
    case system(String, Int32)
    case notMachO
    case unsupported(String)
    case truncated(String)

    public var description: String {
        switch self {
        case let .system(call, code): "\(call): \(String(cString: strerror(code)))"
        case .notMachO: "not a Mach-O file"
        case let .unsupported(what): what
        case let .truncated(what): "truncated or malformed: \(what)"
        }
    }
}

/// A file read-only mapped into memory.
public final class MappedFile: @unchecked Sendable {
    public let bytes: UnsafeRawBufferPointer

    private static let maxBytes = 4 << 30

    /// Maps `descriptor` (kept open by the caller) read-only.
    public init(descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw MachOError.system("fstat", errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw MachOError.unsupported("not a regular file") }
        guard info.st_size > 0 else { throw MachOError.notMachO }
        guard info.st_size <= off_t(Self.maxBytes) else {
            throw MachOError.unsupported("file is larger than \(Self.maxBytes) bytes")
        }
        let size = Int(info.st_size)
        guard let base = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0), base != MAP_FAILED else {
            throw MachOError.system("mmap", errno)
        }
        bytes = UnsafeRawBufferPointer(start: base, count: size)
    }

    /// Opens and maps `path`, canonicalised first.
    public convenience init(path: String) throws {
        guard !path.utf8.contains(0) else { throw MachOError.unsupported("path contains NUL") }
        guard let resolved = realpath(path, nil) else { throw MachOError.system(path, errno) }
        defer { free(resolved) }
        let descriptor = open(resolved, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw MachOError.system(String(cString: resolved), errno) }
        defer { close(descriptor) }
        try self.init(descriptor: descriptor)
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: bytes.baseAddress), bytes.count)
    }
}

/// Bounds-checked little- and big-endian reads from a byte range.
struct ByteReader {
    let bytes: UnsafeRawBufferPointer

    func u32(_ offset: Int, bigEndian: Bool = false) throws -> UInt32 {
        let value: UInt32 = try load(offset)
        return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
    }

    func u64(_ offset: Int, bigEndian: Bool = false) throws -> UInt64 {
        let value: UInt64 = try load(offset)
        return bigEndian ? UInt64(bigEndian: value) : UInt64(littleEndian: value)
    }

    func u8(_ offset: Int) throws -> UInt8 {
        try load(offset)
    }

    func fixedString(_ offset: Int, length: Int) throws -> String {
        guard offset >= 0, length >= 0, offset <= bytes.count - length else {
            throw MachOError.truncated("name at \(offset)")
        }
        let slice = bytes[offset ..< offset + length]
        let end = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(decoding: bytes[offset ..< end], as: UTF8.self)
    }

    /// A NUL-terminated string starting at `offset`, read no further than
    /// `limit`.
    func cString(_ offset: Int, limit: Int) -> String? {
        guard offset >= 0, offset < limit, limit <= bytes.count else { return nil }
        var end = offset
        while end < limit, bytes[end] != 0 {
            end += 1
        }
        guard end < limit else { return nil }
        return String(decoding: bytes[offset ..< end], as: UTF8.self)
    }

    private func load<T: FixedWidthInteger>(_ offset: Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset <= bytes.count - size else { throw MachOError.truncated("read at \(offset)") }
        return bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
    }
}

/// A Mach-O file: one slice, or several in a fat container.
public struct MachOFile {
    public let file: MappedFile
    public let slices: [MachOSlice]

    public init(_ file: MappedFile) throws {
        self.file = file
        let reader = ByteReader(bytes: file.bytes)
        let magic = try reader.u32(0, bigEndian: true)
        switch magic {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            // FAT_MAGIC / FAT_MAGIC_64, big-endian headers.
            let wide = magic == 0xCAFE_BABF
            let count = try Int(reader.u32(4, bigEndian: true))
            // Java class files share 0xCAFEBABE; their "count" is a version.
            guard (1 ... 32).contains(count) else { throw MachOError.notMachO }
            let entrySize = wide ? 32 : 20
            var slices: [MachOSlice] = []
            for index in 0 ..< count {
                let entry = 8 + index * entrySize
                let offset: UInt64
                let size: UInt64
                if wide {
                    offset = try reader.u64(entry + 8, bigEndian: true)
                    size = try reader.u64(entry + 16, bigEndian: true)
                } else {
                    offset = try UInt64(reader.u32(entry + 8, bigEndian: true))
                    size = try UInt64(reader.u32(entry + 12, bigEndian: true))
                }
                guard offset < UInt64(file.bytes.count), size <= UInt64(file.bytes.count) - offset else {
                    throw MachOError.truncated("fat slice \(index)")
                }
                let range = UnsafeRawBufferPointer(rebasing: file.bytes[Int(offset) ..< Int(offset + size)])
                try slices.append(MachOSlice(bytes: range))
            }
            self.slices = slices
        default:
            slices = try [MachOSlice(bytes: file.bytes)]
        }
    }

    /// The slice for `arch` ("arm64", "arm64e", "x86_64"), or the best one
    /// for this device when nil: arm64e, then arm64, then the first.
    public func slice(arch: String?) throws -> MachOSlice {
        if let arch {
            guard let match = slices.first(where: { $0.architecture == arch }) else {
                throw MachOError.unsupported("no \(arch) slice in this file")
            }
            return match
        }
        for preferred in ["arm64e", "arm64"] {
            if let match = slices.first(where: { $0.architecture == preferred }) {
                return match
            }
        }
        return slices[0]
    }
}

public struct MachOSection: Hashable, Sendable {
    public let segment: String
    public let name: String
    public let address: UInt64
    public let size: UInt64
    public let flags: UInt32

    /// S_ATTR_PURE_INSTRUCTIONS or S_ATTR_SOME_INSTRUCTIONS.
    public var containsCode: Bool {
        flags & 0x8000_0000 != 0 || flags & 0x0000_0400 != 0
    }
}

public struct MachOSegment: Hashable, Sendable {
    public let name: String
    public let address: UInt64
    public let fileOffset: UInt64
    public let fileSize: UInt64
}

public struct MachOSymbol: Hashable, Sendable {
    public enum Kind: Sendable {
        case defined
        case undefined
        case absolute
        case indirect
        case preboundUndefined
    }

    public let name: String
    public let address: UInt64
    public let kind: Kind
    public let isExternal: Bool
    /// 1-based section ordinal, 0 when the symbol has none.
    public let section: UInt8

    public var isUndefined: Bool {
        kind == .undefined || kind == .preboundUndefined
    }
}

/// One architecture's image.
public struct MachOSlice {
    public let bytes: UnsafeRawBufferPointer
    public let cpuType: Int32
    public let cpuSubtype: Int32
    public let segments: [MachOSegment]
    public let sections: [MachOSection]
    public let symbols: [MachOSymbol]
    public let uuid: UUID?

    public static let cpuTypeARM64: Int32 = 0x0100_000C
    public static let cpuTypeX86_64: Int32 = 0x0100_0007
    public static let cpuTypeARM64_32: Int32 = 0x0200_000C

    init(bytes: UnsafeRawBufferPointer) throws {
        self.bytes = bytes
        let reader = ByteReader(bytes: bytes)
        let magic = try reader.u32(0)
        switch magic {
        case 0xFEED_FACF: break // MH_MAGIC_64
        case 0xFEED_FACE: throw MachOError.unsupported("32-bit Mach-O is not supported")
        case 0xCFFA_EDFE, 0xCEFA_EDFE: throw MachOError.unsupported("big-endian Mach-O is not supported")
        default: throw MachOError.notMachO
        }
        cpuType = try Int32(bitPattern: reader.u32(4))
        cpuSubtype = try Int32(bitPattern: reader.u32(8))
        let commandCount = try Int(reader.u32(16))
        let commandBytes = try Int(reader.u32(20))
        let headerSize = 32
        guard commandBytes <= bytes.count - headerSize, commandCount <= commandBytes / 8 else {
            throw MachOError.truncated("load commands")
        }

        var segments: [MachOSegment] = []
        var sections: [MachOSection] = []
        var symtab: (symbols: Int, count: Int, strings: Int, stringsSize: Int)?
        var uuid: UUID?
        var offset = headerSize
        let end = headerSize + commandBytes
        for _ in 0 ..< commandCount {
            guard offset + 8 <= end else { throw MachOError.truncated("load command at \(offset)") }
            let command = try reader.u32(offset)
            let size = try Int(reader.u32(offset + 4))
            guard size >= 8, size <= end - offset else { throw MachOError.truncated("load command size at \(offset)") }
            switch command {
            case 0x19: // LC_SEGMENT_64
                guard size >= 72 else { throw MachOError.truncated("segment") }
                let name = try reader.fixedString(offset + 8, length: 16)
                let sectionCount = try Int(reader.u32(offset + 64))
                guard sectionCount <= (size - 72) / 80 else { throw MachOError.truncated("sections of \(name)") }
                var segmentSections: [MachOSection] = []
                for index in 0 ..< sectionCount {
                    let base = offset + 72 + index * 80
                    try segmentSections.append(MachOSection(
                        segment: reader.fixedString(base + 16, length: 16),
                        name: reader.fixedString(base, length: 16),
                        address: reader.u64(base + 32),
                        size: reader.u64(base + 40),
                        flags: reader.u32(base + 64),
                    ))
                }
                try segments.append(MachOSegment(
                    name: name,
                    address: reader.u64(offset + 24),
                    fileOffset: reader.u64(offset + 40),
                    fileSize: reader.u64(offset + 48),
                ))
                sections += segmentSections
            case 0x2: // LC_SYMTAB
                guard size >= 24 else { throw MachOError.truncated("symtab") }
                symtab = try (Int(reader.u32(offset + 8)),
                              Int(reader.u32(offset + 12)),
                              Int(reader.u32(offset + 16)),
                              Int(reader.u32(offset + 20)))
            case 0x1B: // LC_UUID
                guard size >= 24 else { throw MachOError.truncated("uuid") }
                var raw = [UInt8](repeating: 0, count: 16)
                for index in 0 ..< 16 {
                    raw[index] = try reader.u8(offset + 8 + index)
                }
                uuid = UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                                   raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
            default:
                break
            }
            offset += size
        }

        var symbols: [MachOSymbol] = []
        if let symtab {
            guard symtab.strings >= 0, symtab.stringsSize >= 0, symtab.strings <= bytes.count - symtab.stringsSize,
                  symtab.symbols >= 0, symtab.count <= (bytes.count - symtab.symbols) / 16
            else { throw MachOError.truncated("symbol table") }
            let stringsEnd = symtab.strings + symtab.stringsSize
            symbols.reserveCapacity(symtab.count)
            for index in 0 ..< symtab.count {
                let entry = symtab.symbols + index * 16
                let type = try reader.u8(entry + 4)
                guard type & 0xE0 == 0 else { continue } // N_STAB: debugger entries
                let stringIndex = try Int(reader.u32(entry))
                guard let name = reader.cString(symtab.strings + stringIndex, limit: stringsEnd), !name.isEmpty else {
                    continue
                }
                let kind: MachOSymbol.Kind
                switch type & 0x0E {
                case 0x0: kind = .undefined
                case 0x2: kind = .absolute
                case 0xA: kind = .indirect
                case 0xC: kind = .preboundUndefined
                case 0xE: kind = .defined
                default: continue
                }
                try symbols.append(MachOSymbol(
                    name: name,
                    address: reader.u64(entry + 8),
                    kind: kind,
                    isExternal: type & 0x01 != 0,
                    section: reader.u8(entry + 5),
                ))
            }
        }

        self.segments = segments
        self.sections = sections
        self.symbols = symbols
        self.uuid = uuid
    }

    /// "arm64", "arm64e", "x86_64", "arm64_32", or the raw CPU type.
    public var architecture: String {
        switch cpuType {
        case Self.cpuTypeARM64: cpuSubtype & 0x00FF_FFFF == 2 ? "arm64e" : "arm64"
        case Self.cpuTypeX86_64: "x86_64"
        case Self.cpuTypeARM64_32: "arm64_32"
        default: String(format: "cputype 0x%x", cpuType)
        }
    }

    public func section(containing address: UInt64) -> MachOSection? {
        sections.first { address >= $0.address && address - $0.address < $0.size }
    }

    /// Up to `maxCount` bytes of file contents starting at virtual address
    /// `address`, never past the end of the segment's file contents.
    public func bytes(atAddress address: UInt64, maxCount: Int) throws -> UnsafeRawBufferPointer {
        guard let segment = segments.first(where: { address >= $0.address && address - $0.address < $0.fileSize }) else {
            throw MachOError.unsupported(String(format: "0x%llx is not inside any segment's file contents", address))
        }
        let delta = address - segment.address
        let start = segment.fileOffset + delta
        let available = segment.fileSize - delta
        let count = min(UInt64(max(0, maxCount)), available)
        guard start <= UInt64(bytes.count), count <= UInt64(bytes.count) - start else {
            throw MachOError.truncated("segment \(segment.name)")
        }
        return UnsafeRawBufferPointer(rebasing: bytes[Int(start) ..< Int(start + count)])
    }

    /// Defined symbols sorted by address, for lookups.
    public func symbolIndex() -> MachOSymbolIndex {
        MachOSymbolIndex(symbols: symbols)
    }
}

/// Address → nearest preceding defined symbol.
public struct MachOSymbolIndex {
    private let sorted: [MachOSymbol]
    private let exact: [UInt64: MachOSymbol]
    private let byName: [String: MachOSymbol]

    init(symbols: [MachOSymbol]) {
        let defined = symbols.filter { $0.kind == .defined }
        sorted = defined.sorted { $0.address == $1.address ? $0.name < $1.name : $0.address < $1.address }
        // At one address, an external name reads better than a local one.
        var exact: [UInt64: MachOSymbol] = [:]
        for symbol in sorted where exact[symbol.address] == nil || (symbol.isExternal && exact[symbol.address]?.isExternal == false) {
            exact[symbol.address] = symbol
        }
        self.exact = exact
        byName = Dictionary(defined.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func symbol(at address: UInt64) -> MachOSymbol? {
        exact[address]
    }

    public func symbol(named name: String) -> MachOSymbol? {
        byName[name] ?? byName["_" + name]
    }

    /// The closest defined symbol at or before `address`, and the distance.
    public func nearest(_ address: UInt64) -> (symbol: MachOSymbol, offset: UInt64)? {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle].address <= address {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0 else { return nil }
        let candidate = sorted[low - 1]
        let best = exact[candidate.address] ?? candidate
        return (best, address - best.address)
    }
}
