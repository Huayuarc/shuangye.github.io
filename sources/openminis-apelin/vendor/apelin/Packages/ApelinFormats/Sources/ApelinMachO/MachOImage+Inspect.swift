// Adapted from Fila (MIT, OwnGoal Studio): FilaFormats/MachOImage+Inspect.swift.
// Fila decodes the fixed-layout commands with p-x9/MachOKit after checking
// their sizes; here the same handful of layouts (segments and sections, build
// and minimum versions, rpaths, entry point, symbol table, encryption) are
// decoded by hand with the same checks, so the module keeps no dependency and
// may be linked by a privileged process. The bounds checks and the signing
// identity reader are Fila's; the dyld information is Apelin's own.

import Foundation

extension MachOImage {
    /// What one slice's load commands say, copied out into plain values.
    public struct Inspection: Sendable, Hashable {
        /// The header flags by `MH_*` name, without the prefix: `PIE`,
        /// `TWOLEVEL`, `DYLDLINK`.
        public var flags: [String] = []
        /// Every load command in file order.
        public var loadCommands: [LoadCommandSummary] = []
        /// `LC_RPATH`, in the order dyld searches them.
        public var runpaths: [String] = []
        public var segments: [Segment] = []
        /// From `LC_BUILD_VERSION`, or the legacy `LC_VERSION_MIN_*`.
        public var platform: Platform?
        public var minimumOS: String?
        public var sdk: String?
        /// `LC_SOURCE_VERSION`, as `a.b.c.d.e`.
        public var sourceVersion: String?
        /// `LC_MAIN`'s `entryoff`, relative to the slice.
        public var entryOffset: UInt64?
        public var symbolCount: UInt32?
        public var encryptionMethod: UInt32?
        public var encryptedByteCount: UInt32?
        /// `LC_DYLD_INFO` or `LC_DYLD_INFO_ONLY`; absent with chained fixups.
        public var dyldInfo: DyldInfo?
        /// The code directory's identifier (`CFBundleIdentifier` or the file
        /// name for an ad-hoc signature).
        public var signingIdentifier: String?
        public var teamIdentifier: String?
        /// `CS_ADHOC` on the code directory.
        public var isAdHoc: Bool?
    }

    /// The opcode streams dyld rebases and binds a slice by when it has no
    /// chained fixups.
    public struct DyldInfo: Sendable, Hashable {
        public var rebaseByteCount: UInt32
        public var bindOffset: UInt32
        public var bindByteCount: UInt32
        public var lazyBindByteCount: UInt32
        /// arm64e's threaded binds: the stream starts with
        /// `BIND_OPCODE_THREADED`, and every slot keeps the signature the
        /// linker encoded in it.
        public var bindsAreThreaded = false

        /// Whether dyld writes a plain pointer over an arm64e slot whose
        /// signature the linker encoded in it, by a rebase or by a bind that
        /// is not threaded: a constant string's class, an imported function
        /// and every other signed pointer then reach the code unsigned. CLT
        /// 15.0's linker writes such a slice under `-undefined
        /// dynamic_lookup`. Meaningless for any other architecture.
        public var dropsPointerSignatures: Bool {
            rebaseByteCount > 0 || ((bindByteCount > 0 || lazyBindByteCount > 0) && !bindsAreThreaded)
        }
    }

    /// One load command: its `cmd` value, the `LC_*` name when known, and its
    /// size in bytes.
    public struct LoadCommandSummary: Sendable, Hashable {
        public var command: UInt32
        public var name: String
        public var byteCount: UInt32
    }

    public struct Segment: Sendable, Hashable {
        public var name: String
        public var virtualAddress: UInt64
        public var virtualSize: UInt64
        public var fileOffset: UInt64
        public var fileSize: UInt64
        /// `initprot` as `rwx`, `r-x`, `---`.
        public var protections: String
        public var initialProtection: UInt32
        public var maximumProtection: UInt32
        /// Section names in order: `__text`, `__stubs`, ...
        public var sections: [String]
    }

    /// `PLATFORM_*` from `LC_BUILD_VERSION`.
    public struct Platform: Sendable, Hashable, RawRepresentable {
        public var rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let macOS = Platform(rawValue: 1)
        public static let iOS = Platform(rawValue: 2)
        public static let tvOS = Platform(rawValue: 3)
        public static let watchOS = Platform(rawValue: 4)
        public static let bridgeOS = Platform(rawValue: 5)
        public static let macCatalyst = Platform(rawValue: 6)
        public static let iOSSimulator = Platform(rawValue: 7)
        public static let tvOSSimulator = Platform(rawValue: 8)
        public static let watchOSSimulator = Platform(rawValue: 9)
        public static let driverKit = Platform(rawValue: 10)
        public static let visionOS = Platform(rawValue: 11)
        public static let visionOSSimulator = Platform(rawValue: 12)

        /// The name `vtool -show-build` prints, or the number when unknown.
        public var name: String {
            switch rawValue {
            case 1: "macOS"
            case 2: "iOS"
            case 3: "tvOS"
            case 4: "watchOS"
            case 5: "bridgeOS"
            case 6: "macCatalyst"
            case 7: "iOS Simulator"
            case 8: "tvOS Simulator"
            case 9: "watchOS Simulator"
            case 10: "DriverKit"
            case 11: "visionOS"
            case 12: "visionOS Simulator"
            default: "platform \(rawValue)"
            }
        }
    }

    /// Walks the slice's load commands again, decoding the ones a properties
    /// screen or a build check asks about. Only the header and the command
    /// region are read, plus the code directory's fixed fields and the first
    /// bind opcode; page hashes never are.
    public func inspect(_ slice: Slice) throws -> Inspection {
        guard slices.contains(slice) else { throw FormatFailure.damaged("this architecture is not in the file") }
        let big = slice.isBigEndian
        let headerSize = slice.isSixtyFourBit ? 32 : 28
        let header = try reader.read(at: slice.offset, count: headerSize)
        let count: UInt32 = try header.integer(at: 16, bigEndian: big)
        let length: UInt32 = try header.integer(at: 20, bigEndian: big)
        guard count <= 16384, UInt64(count) * 8 <= length,
              Int64(length) <= min(slice.byteCount - Int64(headerSize), Self.maximumLoadCommandByteCount)
        else {
            throw FormatFailure.damaged("its load commands could not be read")
        }
        let data = try reader.read(at: slice.offset + Int64(headerSize), count: Int(length))
        var result = Inspection()
        result.flags = Self.headerFlagNames.filter { slice.headerFlags & $0.bit != 0 }.map(\.name)
        var cursor = 0
        for _ in 0 ..< count {
            guard data.count - cursor >= 8 else { throw FormatFailure.damaged("its load command list is truncated") }
            let command: UInt32 = try data.integer(at: cursor, bigEndian: big)
            let size = try Int(data.integer(at: cursor + 4, bigEndian: big) as UInt32)
            guard size >= 8, size % (slice.isSixtyFourBit ? 8 : 4) == 0, size <= data.count - cursor else {
                throw FormatFailure.damaged("part of its header is the wrong size")
            }
            let bytes = data.subdata(in: data.startIndex + cursor ..< data.startIndex + cursor + size)
            result.loadCommands.append(LoadCommandSummary(
                command: command,
                name: Self.loadCommandNames[command] ?? String(format: "0x%08X", command),
                byteCount: UInt32(size),
            ))
            if let minimum = Self.decodedCommandSizes[command] {
                guard size >= minimum else { throw FormatFailure.damaged("a load command is truncated") }
                try Self.decode(command, bytes, slice: slice, into: &result)
            }
            cursor += size
        }
        guard cursor == data.count else { throw FormatFailure.damaged("its load commands do not match the header") }
        if let info = result.dyldInfo, info.bindByteCount > 0 {
            let first = try reader.read(at: slice.offset + Int64(info.bindOffset), count: 1)
            result.dyldInfo?.bindsAreThreaded = first.first.map { $0 & 0xF0 == 0xD0 } ?? false
        }
        try readSigningIdentity(slice, into: &result)
        return result
    }

    /// The smallest size each decoded command can have. A shorter one is
    /// damage, not something to read past.
    private static let decodedCommandSizes: [UInt32: Int] = [
        0x1: 56, 0x19: 72, // segments
        0x2: 24, // symbol table
        0x21: 20, 0x2C: 24, // encryption info
        0x24: 16, 0x25: 16, 0x2F: 16, 0x30: 16, // legacy minimum versions
        0x32: 24, 0x2A: 16, 0x8000_0028: 24, // build/source versions, entry point
        0x8000_001C: 12, // rpath
        0x22: 48, 0x8000_0022: 48, // dyld info
    ]

    private static func decode(_ command: UInt32, _ bytes: Data, slice: Slice, into result: inout Inspection) throws {
        let big = slice.isBigEndian
        func u32(_ at: Int) throws -> UInt32 {
            try bytes.integer(at: at, bigEndian: big)
        }
        func u64(_ at: Int) throws -> UInt64 {
            try bytes.integer(at: at, bigEndian: big)
        }
        switch command {
        case 0x19:
            try result.segments.append(segment(
                bytes,
                address: u64(24),
                size: u64(32),
                offset: u64(40),
                fileSize: u64(48),
                maximumProtection: u32(56),
                initialProtection: u32(60),
                sectionCount: u32(64),
                headerSize: 72,
                sectionSize: 80,
                slice: slice,
            ))
        case 0x1:
            try result.segments.append(segment(
                bytes,
                address: UInt64(u32(24)),
                size: UInt64(u32(28)),
                offset: UInt64(u32(32)),
                fileSize: UInt64(u32(36)),
                maximumProtection: u32(40),
                initialProtection: u32(44),
                sectionCount: u32(48),
                headerSize: 56,
                sectionSize: 68,
                slice: slice,
            ))
        case 0x32:
            let tools = try u32(20)
            guard UInt64(tools) * 8 <= UInt64(bytes.count - 24) else {
                throw FormatFailure.damaged("its version information is truncated")
            }
            result.platform = try Platform(rawValue: u32(8))
            result.minimumOS = try versionString(u32(12))
            result.sdk = try versionString(u32(16))
        case 0x24, 0x25, 0x2F, 0x30:
            result.minimumOS = try versionString(u32(8))
            result.sdk = try versionString(u32(12))
            result.platform = switch command {
            case 0x24: .macOS
            case 0x25: .iOS
            case 0x2F: .tvOS
            default: .watchOS
            }
        case 0x21, 0x2C:
            result.encryptedByteCount = try u32(12)
            result.encryptionMethod = try u32(16)
        case 0x2A:
            result.sourceVersion = try sourceVersionString(u64(8))
        case 0x8000_0028:
            let entry = try u64(8)
            guard entry < slice.byteCount else {
                throw FormatFailure.damaged("its entry offset is outside this architecture")
            }
            result.entryOffset = entry
        case 0x2:
            let symbolOffset = try UInt64(u32(8)), symbols = try UInt64(u32(12))
            let stringOffset = try UInt64(u32(16)), stringSize = try UInt64(u32(20))
            let symbolSize: UInt64 = slice.isSixtyFourBit ? 16 : 12
            let limit = UInt64(slice.byteCount)
            guard symbolOffset <= limit, symbols * symbolSize <= limit - symbolOffset,
                  stringOffset <= limit, stringSize <= limit - stringOffset
            else {
                throw FormatFailure.damaged("its symbols are outside this architecture")
            }
            result.symbolCount = UInt32(symbols)
        case 0x8000_001C:
            let relative = try u32(8)
            guard relative >= 12, relative < bytes.count else {
                throw FormatFailure.damaged("a runpath entry is invalid")
            }
            try result.runpaths.append(terminatedString(bytes, at: Int(relative)))
        case 0x22, 0x8000_0022:
            // Rebase, bind, weak bind, lazy bind and export streams, each an
            // offset and a size.
            let limit = UInt64(slice.byteCount)
            for field in stride(from: 8, to: 48, by: 8) {
                let offset = try UInt64(u32(field)), size = try UInt64(u32(field + 4))
                guard offset <= limit, size <= limit - offset else {
                    throw FormatFailure.damaged("its dyld information is outside this architecture")
                }
            }
            result.dyldInfo = try DyldInfo(
                rebaseByteCount: u32(12),
                bindOffset: u32(16),
                bindByteCount: u32(20),
                lazyBindByteCount: u32(36),
            )
        default:
            break
        }
    }

    private static func segment(
        _ bytes: Data,
        address: UInt64,
        size: UInt64,
        offset: UInt64,
        fileSize: UInt64,
        maximumProtection: UInt32,
        initialProtection: UInt32,
        sectionCount: UInt32,
        headerSize: Int,
        sectionSize: Int,
        slice: Slice,
    ) throws -> Segment {
        let limit = UInt64(slice.byteCount)
        guard offset <= limit, fileSize <= limit - offset,
              UInt64(sectionCount) * UInt64(sectionSize) <= UInt64(bytes.count - headerSize)
        else {
            throw FormatFailure.damaged("a segment or section is outside this architecture")
        }
        let names = try (0 ..< Int(sectionCount)).map {
            try bytes.string(at: headerSize + $0 * sectionSize, count: 16)
        }
        let permissions = (initialProtection & 1 != 0 ? "r" : "-")
            + (initialProtection & 2 != 0 ? "w" : "-") + (initialProtection & 4 != 0 ? "x" : "-")
        return try Segment(
            name: bytes.string(at: 8, count: 16),
            virtualAddress: address,
            virtualSize: size,
            fileOffset: offset,
            fileSize: fileSize,
            protections: permissions,
            initialProtection: initialProtection,
            maximumProtection: maximumProtection,
            sections: names,
        )
    }

    private static func terminatedString(_ bytes: Data, at offset: Int) throws -> String {
        let base = bytes.startIndex
        guard offset >= 0, offset < bytes.count,
              let end = bytes[(base + offset) ..< (base + bytes.count)].firstIndex(of: 0)
        else {
            throw FormatFailure.damaged("a name inside it is truncated")
        }
        return String(decoding: bytes[(base + offset) ..< end], as: UTF8.self)
    }

    /// `xxxx.yy.zz` packed as nibbles, the way `LC_BUILD_VERSION` stores it.
    private static func versionString(_ value: UInt32) -> String {
        "\(value >> 16).\((value >> 8) & 255).\(value & 255)"
    }

    /// `a.b.c.d.e` packed as 24.10.10.10.10 bits.
    private static func sourceVersionString(_ value: UInt64) -> String {
        let parts = [value >> 40, (value >> 30) & 0x3FF, (value >> 20) & 0x3FF, (value >> 10) & 0x3FF, value & 0x3FF]
        return parts.map(String.init).joined(separator: ".")
    }

    /// Read the superblob index and fixed CodeDirectory fields, then bounded
    /// identifier strings. Page hashes are never loaded into memory.
    private func readSigningIdentity(_ slice: Slice, into result: inout Inspection) throws {
        guard let signature = slice.signature, signature.byteCount >= 12 else { return }
        let head = try reader.read(at: signature.offset, count: 12)
        guard try head.bigEndian(at: 0) as UInt32 == Self.embeddedSignatureMagic else { return }
        let length = try Int64(head.bigEndian(at: 4) as UInt32)
        let count = try Int(head.bigEndian(at: 8) as UInt32)
        guard length <= signature.byteCount, count <= 64, 12 + count * 8 <= length else {
            throw FormatFailure.damaged("its code signature is invalid")
        }
        let index = try reader.read(at: signature.offset + 12, count: count * 8)
        for number in 0 ..< count {
            let offset = try Int64(index.bigEndian(at: number * 8 + 4) as UInt32)
            guard offset >= 12 + Int64(count) * 8, offset <= length - 8 else {
                throw FormatFailure.damaged("its code signature is invalid")
            }
            let blobHeader = try reader.read(at: signature.offset + offset, count: 8)
            guard try blobHeader.bigEndian(at: 0) as UInt32 == 0xFADE_0C02 else { continue }
            let blobLength = try Int64(blobHeader.bigEndian(at: 4) as UInt32)
            guard blobLength >= 44, blobLength <= length - offset else {
                throw FormatFailure.damaged("its code signature is truncated")
            }
            let directory = try reader.read(at: signature.offset + offset, count: Int(min(blobLength, 52)))
            let version: UInt32 = try directory.bigEndian(at: 8)
            let flags: UInt32 = try directory.bigEndian(at: 12)
            let identifier = try Int64(directory.bigEndian(at: 20) as UInt32)
            func string(_ relative: Int64) throws -> String? {
                guard relative != 0 else { return nil }
                let minimum: Int64 = version >= 0x20200 ? 52 : 44
                guard relative >= minimum, relative < blobLength else {
                    throw FormatFailure.damaged("its signing identifier is invalid")
                }
                let bytes = try reader.read(
                    at: signature.offset + offset + relative,
                    count: Int(min(4096, blobLength - relative)),
                )
                return try Self.terminatedString(bytes, at: 0)
            }
            result.isAdHoc = flags & 2 != 0
            result.signingIdentifier = try string(identifier)
            if version >= 0x20200 {
                guard directory.count >= 52 else { throw FormatFailure.damaged("its team identifier is truncated") }
                result.teamIdentifier = try string(Int64(directory.bigEndian(at: 48) as UInt32))
            }
            return
        }
    }

    private static let headerFlagNames: [(bit: UInt32, name: String)] = [
        (0x1, "NOUNDEFS"), (0x2, "INCRLINK"), (0x4, "DYLDLINK"), (0x8, "BINDATLOAD"),
        (0x10, "PREBOUND"), (0x20, "SPLIT_SEGS"), (0x40, "LAZY_INIT"), (0x80, "TWOLEVEL"),
        (0x100, "FORCE_FLAT"), (0x200, "NOMULTIDEFS"), (0x400, "NOFIXPREBINDING"), (0x800, "PREBINDABLE"),
        (0x1000, "ALLMODSBOUND"), (0x2000, "SUBSECTIONS_VIA_SYMBOLS"), (0x4000, "CANONICAL"),
        (0x8000, "WEAK_DEFINES"), (0x10000, "BINDS_TO_WEAK"), (0x20000, "ALLOW_STACK_EXECUTION"),
        (0x40000, "ROOT_SAFE"), (0x80000, "SETUID_SAFE"), (0x100000, "NO_REEXPORTED_DYLIBS"),
        (0x200000, "PIE"), (0x400000, "DEAD_STRIPPABLE_DYLIB"), (0x800000, "HAS_TLV_DESCRIPTORS"),
        (0x1000000, "NO_HEAP_EXECUTION"), (0x2000000, "APP_EXTENSION_SAFE"),
        (0x4000000, "NLIST_OUTOFSYNC_WITH_DYLDINFO"), (0x8000000, "SIM_SUPPORT"),
        (0x8000_0000, "DYLIB_IN_CACHE"),
    ]

    /// `<mach-o/loader.h>`'s names, spelled out for the reason the header
    /// constants are: they are part of the parser, not of the host.
    private static let loadCommandNames: [UInt32: String] = [
        0x1: "LC_SEGMENT", 0x2: "LC_SYMTAB", 0x3: "LC_SYMSEG", 0x4: "LC_THREAD", 0x5: "LC_UNIXTHREAD",
        0x6: "LC_LOADFVMLIB", 0x7: "LC_IDFVMLIB", 0x8: "LC_IDENT", 0x9: "LC_FVMFILE", 0xA: "LC_PREPAGE",
        0xB: "LC_DYSYMTAB", 0xC: "LC_LOAD_DYLIB", 0xD: "LC_ID_DYLIB", 0xE: "LC_LOAD_DYLINKER",
        0xF: "LC_ID_DYLINKER", 0x10: "LC_PREBOUND_DYLIB", 0x11: "LC_ROUTINES", 0x12: "LC_SUB_FRAMEWORK",
        0x13: "LC_SUB_UMBRELLA", 0x14: "LC_SUB_CLIENT", 0x15: "LC_SUB_LIBRARY", 0x16: "LC_TWOLEVEL_HINTS",
        0x17: "LC_PREBIND_CKSUM", 0x8000_0018: "LC_LOAD_WEAK_DYLIB", 0x19: "LC_SEGMENT_64",
        0x1A: "LC_ROUTINES_64", 0x1B: "LC_UUID", 0x8000_001C: "LC_RPATH", 0x1D: "LC_CODE_SIGNATURE",
        0x1E: "LC_SEGMENT_SPLIT_INFO", 0x8000_001F: "LC_REEXPORT_DYLIB", 0x20: "LC_LAZY_LOAD_DYLIB",
        0x21: "LC_ENCRYPTION_INFO", 0x22: "LC_DYLD_INFO", 0x8000_0022: "LC_DYLD_INFO_ONLY",
        0x8000_0023: "LC_LOAD_UPWARD_DYLIB", 0x24: "LC_VERSION_MIN_MACOSX", 0x25: "LC_VERSION_MIN_IPHONEOS",
        0x26: "LC_FUNCTION_STARTS", 0x27: "LC_DYLD_ENVIRONMENT", 0x8000_0028: "LC_MAIN",
        0x29: "LC_DATA_IN_CODE", 0x2A: "LC_SOURCE_VERSION", 0x2B: "LC_DYLIB_CODE_SIGN_DRS",
        0x2C: "LC_ENCRYPTION_INFO_64", 0x2D: "LC_LINKER_OPTION", 0x2E: "LC_LINKER_OPTIMIZATION_HINT",
        0x2F: "LC_VERSION_MIN_TVOS", 0x30: "LC_VERSION_MIN_WATCHOS", 0x31: "LC_NOTE", 0x32: "LC_BUILD_VERSION",
        0x8000_0033: "LC_DYLD_EXPORTS_TRIE", 0x8000_0034: "LC_DYLD_CHAINED_FIXUPS",
        0x8000_0035: "LC_FILESET_ENTRY", 0x36: "LC_ATOM_INFO", 0x37: "LC_FUNCTION_VARIANTS",
        0x38: "LC_FUNCTION_VARIANT_FIXUPS", 0x39: "LC_TARGET_TRIPLE",
    ]
}
