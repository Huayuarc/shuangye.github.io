import ApelinCodeSign
import Foundation

/// Only arm64 little-endian execution images are selected. Fat inputs are validated before thinning.
struct MachOImage {
    struct Command { var bytes: Data; var kind: UInt32 {
        try! bytes.number(0)
    } }
    private(set) var bytes: Data
    var commands: [Command]
    let fileType: UInt32
    let firstContent: Int
    var dependencies: [String] {
        get throws { try commands.filter { Self.loads.contains($0.kind) }.map { try Self.name($0) } }
    }

    var rpaths: [String] {
        get throws { try commands.filter { $0.kind == 0x8000_001C }.map { try Self.name($0) } }
    }

    static let loads: Set<UInt32> = [0xC, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023]
    /// Commands that carry a path: the loads, LC_ID_DYLIB and LC_RPATH.
    static let namedCommands = loads.union([0xD, 0x8000_001C])
    /// LC_DYLD_INFO and LC_DYLD_INFO_ONLY.
    static let dyldInfo: Set<UInt32> = [0x22, 0x8000_0022]
    static func armSlice(_ data: Data) throws -> Data {
        let magic: UInt32 = try data.number(0)
        if magic == 0xFEED_FACF {
            return data
        }
        guard magic == 0xBEBA_FECA else { throw ToolchainFailure("Unsupported Mach-O architecture or magic") }
        let count = try Int(data.number(4, as: UInt32.self, big: true))
        guard count > 0, count <= 32, 8 + count * 20 <= data.count else {
            throw ToolchainFailure("Invalid fat Mach-O header")
        }
        var selected: Data?
        var ranges: [Range<Int>] = []
        for i in 0 ..< count {
            let p = 8 + i * 20
            let cpu = try data.number(p, as: UInt32.self, big: true)
            let offset = try Int(data.number(p + 8, as: UInt32.self, big: true)),
                size = try Int(data.number(p + 12, as: UInt32.self, big: true))
            guard
                offset >= 8 + count * 20,
                offset <= data.count,
                size <= data.count - offset,
                !ranges.contains(where: { $0.overlaps(offset ..< offset + size) })
            else {
                throw ToolchainFailure("Invalid fat Mach-O slice")
            }
            ranges.append(offset ..< offset + size)
            if cpu == 0x100000C, selected == nil {
                selected = data.subdata(in: offset ..< offset + size)
            }
        }
        guard let selected else { throw ToolchainFailure("Tool contains no arm64 slice") }
        return selected
    }

    init(_ input: Data, allowDSYM: Bool = false) throws {
        bytes = try Self.armSlice(input)
        guard
            bytes.count >= 32,
            try bytes.number(0, as: UInt32.self) == 0xFEED_FACF,
            try bytes.number(4, as: UInt32.self) == 0x100000C
        else {
            throw ToolchainFailure("Tool is not arm64 Mach-O")
        }
        fileType = try bytes.number(12)
        guard [2, 6, 8].contains(fileType) || (allowDSYM && fileType == 10) else {
            throw ToolchainFailure("Unsupported Mach-O file type")
        }
        let n = try Int(bytes.number(16, as: UInt32.self)), length = try Int(bytes.number(20, as: UInt32.self))
        guard length <= bytes.count - 32, n <= length / 8 else {
            throw ToolchainFailure("Invalid Mach-O load-command region")
        }
        var at = 32, content = bytes.count
        var parsed: [Command] = []
        for _ in 0 ..< n {
            let size = try Int(bytes.number(at + 4, as: UInt32.self))
            guard size >= 8, size % 8 == 0, size <= 32 + length - at else {
                throw ToolchainFailure("Invalid Mach-O load-command size")
            }
            let command = Command(bytes: bytes.subdata(in: at ..< at + size))
            let imageCount = UInt64(bytes.count)
            func extent(_ offset: UInt64, _ size: UInt64) throws {
                guard offset <= imageCount, size <= imageCount - offset else {
                    throw ToolchainFailure("Mach-O data extent outside image")
                }
            }
            let linkData: Set<UInt32> = [0x1D, 0x1E, 0x26, 0x29, 0x2B, 0x2E, 0x8000_0033, 0x8000_0034]
            if linkData.contains(command.kind) {
                guard size == 16 else { throw ToolchainFailure("Invalid linkedit data command") }
                try extent(
                    UInt64(command.bytes.number(8, as: UInt32.self)),
                    UInt64(command.bytes.number(12, as: UInt32.self)),
                )
            }
            if command.kind == 2 {
                guard size == 24 else { throw ToolchainFailure("Invalid symbol table command") }
                try extent(
                    UInt64(command.bytes.number(8, as: UInt32.self)),
                    UInt64(command.bytes.number(12, as: UInt32.self)) * 16,
                )
                try extent(
                    UInt64(command.bytes.number(16, as: UInt32.self)),
                    UInt64(command.bytes.number(20, as: UInt32.self)),
                )
            }
            if Self.dyldInfo.contains(command.kind) {
                guard size == 48 else { throw ToolchainFailure("Invalid dyld info command") }
                for field in stride(from: 8, to: 48, by: 8) {
                    try extent(
                        UInt64(command.bytes.number(field, as: UInt32.self)),
                        UInt64(command.bytes.number(field + 4, as: UInt32.self)),
                    )
                }
            }
            if command.kind == 0x32 {
                guard size >= 24, try Int(command.bytes.number(20, as: UInt32.self)) <= (size - 24) / 8 else {
                    throw ToolchainFailure("Truncated build-version tools")
                }
            }
            if [0x24, 0x25].contains(command.kind), size != 16 {
                throw ToolchainFailure("Invalid minimum-version command")
            }
            if command.kind == 0x8000_0028 {
                guard size == 24 else { throw ToolchainFailure("Invalid entry-point command") }
                try extent(command.bytes.number(8, as: UInt64.self), 1)
            }
            if command.kind == 0x19 {
                guard size >= 72 else { throw ToolchainFailure("Truncated segment") }
                let offset = try command.bytes.number(40, as: UInt64.self),
                    sizeOnDisk = try command.bytes.number(48, as: UInt64.self)
                guard offset <= bytes.count, sizeOnDisk <= UInt64(bytes.count) - offset else {
                    throw ToolchainFailure("Segment outside image")
                }
                let sections = try Int(command.bytes.number(64, as: UInt32.self))
                guard sections <= (size - 72) / 80 else { throw ToolchainFailure("Truncated sections") }
                if sections == 0, sizeOnDisk > 0, offset > 0 {
                    content = min(content, Int(offset))
                }
                for s in 0 ..< sections {
                    let p = 72 + 80 * s
                    let flags = try command.bytes.number(p + 64, as: UInt32.self) & 0xFF
                    if [1, 0xC, 0x12].contains(flags) {
                        continue
                    } // zero-fill sections have no file extent
                    let offset = try Int(command.bytes.number(p + 48, as: UInt32.self)),
                        sectionSize = try command.bytes.number(p + 40, as: UInt64.self)
                    // dSYM keeps the original image's virtual sections without their bytes, at offset 0.
                    // An older dsymutil copies __eh_frame into the dSYM, so the segment then has file
                    // bytes while its other sections still have none.
                    if sectionSize == 0 || (fileType == 10 && offset == 0) {
                        continue
                    }
                    guard offset >= 32 + length, offset <= bytes.count, sectionSize <= bytes.count - offset else {
                        throw ToolchainFailure("Section outside image or overlapping commands")
                    }
                    content = min(content, offset)
                }
            }
            if Self.namedCommands.contains(command.kind) {
                _ = try Self.name(command)
            }
            parsed.append(command); at += size
        }
        guard at == 32 + length else { throw ToolchainFailure("Mach-O command count mismatch") }
        commands = parsed; firstContent = content
    }

    static func name(_ command: Command) throws -> String {
        let start = try Int(command.bytes.number(8, as: UInt32.self))
        guard start >= (command.kind == 0x8000_001C ? 12 : 24), start < command.bytes.count else {
            throw ToolchainFailure("Invalid load-command string offset")
        }
        return try command.bytes.cString(start ..< command.bytes.count)
    }

    static func isMacOSOnly(_ name: String) -> Bool {
        name.contains("AppKit.framework") || name.contains("Cocoa.framework") || name.contains("Carbon.framework")
    }

    static func flattened(_ path: String) -> String {
        let parts = path.components(separatedBy: "/")
        var result: [String] = []; var i = 0
        while i < parts.count {
            if parts[i] == "Versions", i > 0, parts[i - 1].hasSuffix(".framework"), i + 1 < parts.count {
                i += 2
            } else {
                result.append(parts[i]); i += 1
            }
        }
        return result.joined(separator: "/")
    }

    /// Turns each required load of one of `names` into a weak load (LC_LOAD_DYLIB →
    /// LC_LOAD_WEAK_DYLIB) and marks every symbol bound from it at launch as a weak
    /// import, so dyld starts the image without the library and binds those symbols
    /// to null. Lazy binds stay as they are: dyld resolves one only when it is first
    /// called, and stops the process naming the symbol then. Answers the names it
    /// weakened.
    mutating func weakenLoads(of names: Set<String>) throws -> [String] {
        var weakened: [String] = []
        var ordinals: Set<Int> = []
        var ordinal = 0
        for i in commands.indices where Self.loads.contains(commands[i].kind) {
            ordinal += 1
            guard commands[i].kind == 0xC else { continue }
            let name = try Self.name(commands[i])
            guard names.contains(name) else { continue }
            commands[i].bytes.put(UInt32(0x8000_0018), at: 0)
            weakened.append(name)
            ordinals.insert(ordinal)
        }
        guard !ordinals.isEmpty else { return weakened }
        for command in commands {
            if command.kind == 0x8000_0034 {
                try weakenChainedImports(
                    at: Int(command.bytes.number(8, as: UInt32.self)),
                    size: Int(command.bytes.number(12, as: UInt32.self)),
                    ordinals: ordinals,
                )
            } else if Self.dyldInfo.contains(command.kind) {
                try weakenBindOpcodes(
                    at: Int(command.bytes.number(16, as: UInt32.self)),
                    size: Int(command.bytes.number(20, as: UInt32.self)),
                    ordinals: ordinals,
                )
            }
        }
        return weakened
    }

    /// Binds an import to another symbol of the same library, by rewriting its
    /// name in the chained-fixup symbol pool in place (the new name may not be
    /// longer, and no other import may share the old name's bytes). Answers the
    /// old names it rewrote. An image that binds through LC_DYLD_INFO instead,
    /// where names sit inline in the opcode stream, is refused when it imports
    /// one of them.
    mutating func renameImports(_ renames: [String: String]) throws -> [String] {
        guard !renames.isEmpty else { return [] }
        var renamed: [String] = []
        for command in commands {
            if Self.dyldInfo.contains(command.kind) {
                let symbols = try Set(bindSymbolNames(command))
                if let name = renames.keys.first(where: { symbols.contains($0) }) {
                    throw ToolchainFailure("Cannot rebind \(name): the image binds through dyld info")
                }
                continue
            }
            guard command.kind == 0x8000_0034 else { continue }
            let offset = try Int(command.bytes.number(8, as: UInt32.self))
            let size = try Int(command.bytes.number(12, as: UInt32.self))
            let (importsOffset, symbolsOffset, count, format, stride) = try chainedFixupsHeader(at: offset, size: size)
            guard try bytes.number(offset + 24, as: UInt32.self) == 0 else {
                throw ToolchainFailure("Compressed chained-fixup symbols are not supported")
            }
            guard stride > 0, importsOffset <= size, count <= (size - importsOffset) / stride,
                  symbolsOffset <= size
            else {
                throw ToolchainFailure("Chained imports outside their command")
            }
            let pool = offset + symbolsOffset, end = offset + size
            var nameOffsets: [Int] = []
            for index in 0 ..< count {
                let at = offset + importsOffset + index * stride
                try nameOffsets.append(format == 3
                    ? Int(bytes.number(at, as: UInt64.self) >> 32)
                    : Int(bytes.number(at, as: UInt32.self) >> 9))
            }
            for nameOffset in Set(nameOffsets) {
                guard pool + nameOffset < end else { throw ToolchainFailure("Chained import name outside its pool") }
                let name = try bytes.cString(pool + nameOffset ..< end)
                guard let replacement = renames[name] else { continue }
                guard replacement.utf8.count <= name.utf8.count, !replacement.utf8.contains(0) else {
                    throw ToolchainFailure("Cannot rebind \(name) to a longer name")
                }
                // Another import's name must not start inside this one (a shared suffix), nor run
                // on into it (this one the tail of a longer name: no NUL between their starts).
                let span = pool + nameOffset ..< pool + nameOffset + name.utf8.count + 1
                let shared = nameOffsets.contains { other in
                    if other == nameOffset {
                        return false
                    }
                    if other > nameOffset {
                        return span.contains(pool + other)
                    }
                    return !bytes[bytes.startIndex + pool + other ..< bytes.startIndex + span.lowerBound].contains(0)
                }
                guard !shared else {
                    throw ToolchainFailure("Cannot rebind \(name): its bytes are shared")
                }
                var replaced = Data(replacement.utf8)
                replaced.append(Data(count: span.count - replaced.count))
                bytes.replaceSubrange(
                    bytes.startIndex + span.lowerBound ..< bytes.startIndex + span.upperBound,
                    with: replaced,
                )
                renamed.append(name)
            }
        }
        return renamed
    }

    /// The symbol names LC_DYLD_INFO's regular and lazy bind streams name.
    private func bindSymbolNames(_ command: Command) throws -> [String] {
        var names: [String] = []
        for field in [16, 32] {
            let offset = try Int(command.bytes.number(field, as: UInt32.self))
            let size = try Int(command.bytes.number(field + 4, as: UInt32.self))
            guard size > 0 else { continue }
            guard offset >= 0, offset <= bytes.count, size <= bytes.count - offset else {
                throw ToolchainFailure("Bind opcodes outside image")
            }
            // Names follow BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM; scanning for every
            // C string that starts with "_" after a 0x4x byte finds each one.
            let base = bytes.startIndex
            var at = offset
            while at < offset + size {
                if bytes[base + at] & 0xF0 == 0x40, at + 1 < offset + size, bytes[base + at + 1] == 0x5F,
                   let name = try? bytes.cString(at + 1 ..< offset + size)
                {
                    names.append(name)
                    at += 1 + name.utf8.count + 1
                } else {
                    at += 1
                }
            }
        }
        return names
    }

    /// LC_DYLD_CHAINED_FIXUPS' header, at `offset` in the image and checked to
    /// lie inside it: where the imports and the symbol pool start (from the
    /// header), how many imports, their format and its stride (0 for a format
    /// this reader does not know).
    private func chainedFixupsHeader(at offset: Int, size: Int) throws
        -> (importsOffset: Int, symbolsOffset: Int, count: Int, format: UInt32, stride: Int)
    {
        guard offset >= 0, size >= 28, offset <= bytes.count, size <= bytes.count - offset else {
            throw ToolchainFailure("Chained fixups outside image")
        }
        let format = try bytes.number(offset + 20, as: UInt32.self)
        return try (
            Int(bytes.number(offset + 8, as: UInt32.self)),
            Int(bytes.number(offset + 12, as: UInt32.self)),
            Int(bytes.number(offset + 16, as: UInt32.self)),
            format,
            format == 1 ? 4 : format == 2 ? 8 : format == 3 ? 16 : 0,
        )
    }

    /// LC_DYLD_CHAINED_FIXUPS: sets `weak_import` on each import from `ordinals`.
    private mutating func weakenChainedImports(at offset: Int, size: Int, ordinals: Set<Int>) throws {
        let (importsOffset, _, count, format, stride) = try chainedFixupsHeader(at: offset, size: size)
        guard stride > 0 else { throw ToolchainFailure("Unknown chained import format \(format)") }
        guard importsOffset <= size, count <= (size - importsOffset) / stride else {
            throw ToolchainFailure("Chained imports outside their command")
        }
        for index in 0 ..< count {
            let at = offset + importsOffset + index * stride
            if format == 3 {
                let value = try bytes.number(at, as: UInt64.self)
                if ordinals.contains(Int(value & 0xFFFF)) {
                    bytes.put(value | (1 << 16), at: at)
                }
            } else {
                let value = try bytes.number(at, as: UInt32.self)
                if ordinals.contains(Int(value & 0xFF)) {
                    bytes.put(value | (1 << 8), at: at)
                }
            }
        }
    }

    /// LC_DYLD_INFO's bind stream: sets BIND_SYMBOL_FLAGS_WEAK_IMPORT on each symbol
    /// opcode a bind from `ordinals` uses.
    private mutating func weakenBindOpcodes(at offset: Int, size: Int, ordinals: Set<Int>) throws {
        guard size > 0 else { return }
        guard offset >= 0, offset <= bytes.count, size <= bytes.count - offset else {
            throw ToolchainFailure("Bind opcodes outside image")
        }
        let base = bytes.startIndex, end = offset + size
        var at = offset, ordinal = 0
        var symbol: Int?
        func uleb() throws -> UInt64 {
            var value: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard at < end, shift < 64 else { throw ToolchainFailure("Truncated bind opcodes") }
                let byte = bytes[base + at]
                at += 1
                value |= UInt64(byte & 0x7F) << shift
                shift += 7
                if byte & 0x80 == 0 {
                    return value
                }
            }
        }
        func bound() {
            if let symbol, ordinals.contains(ordinal) {
                bytes[base + symbol] |= 1
            }
        }
        while at < end {
            let byte = bytes[base + at]
            let opcode = byte & 0xF0, immediate = Int(byte & 0x0F)
            let start = at
            at += 1
            switch opcode {
            case 0x00: return
            case 0x10: ordinal = immediate
            case 0x20: ordinal = try Int(truncatingIfNeeded: uleb())
            case 0x30: ordinal = 0
            case 0x40:
                symbol = start
                while at < end, bytes[base + at] != 0 {
                    at += 1
                }
                guard at < end else { throw ToolchainFailure("Truncated bind symbol") }
                at += 1
            case 0x50: break
            case 0x60, 0x70, 0x80: _ = try uleb()
            case 0x90, 0xB0: bound()
            case 0xA0: _ = try uleb(); bound()
            case 0xC0: _ = try uleb(); _ = try uleb(); bound()
            case 0xD0:
                if immediate == 0 {
                    _ = try uleb()
                } else if immediate == 1 {
                    bound()
                }
            default: throw ToolchainFailure("Unknown bind opcode \(byte)")
            }
        }
    }

    mutating func retarget(minimumOS: UInt32, rewrite: (String, UInt32) throws -> String) throws {
        var hasPlatform = false
        for i in commands.indices {
            let kind = commands[i].kind
            if kind == 0x32 {
                guard commands[i].bytes.count >= 24 else { throw ToolchainFailure("Truncated build-version command") }
                let platform = try commands[i].bytes.number(8, as: UInt32.self)
                guard platform == 1 || platform == 2 else { throw ToolchainFailure("Unsupported source platform") }
                commands[i].bytes.put(UInt32(2), at: 8); commands[i].bytes.put(minimumOS, at: 12); commands[i].bytes.put(minimumOS, at: 16)
                hasPlatform = true
            } else if kind == 0x24 || kind == 0x25 {
                var replacement = Data(count: 24)
                replacement.put(UInt32(0x32), at: 0); replacement.put(UInt32(24), at: 4)
                replacement.put(UInt32(2), at: 8); replacement.put(minimumOS, at: 12); replacement.put(minimumOS, at: 16)
                commands[i].bytes = replacement; hasPlatform = true
            } else if Self.namedCommands.contains(kind) {
                let name = try Self.name(commands[i])
                guard !Self.isMacOSOnly(name) else {
                    throw ToolchainFailure("Unsupported macOS framework dependency: \(name)")
                }
                let replacement = try rewrite(Self.flattened(name), kind)
                guard !replacement.utf8.contains(0) else { throw ToolchainFailure("NUL in load-command name") }
                let start = try Int(commands[i].bytes.number(8, as: UInt32.self))
                var command = Data(commands[i].bytes.prefix(start)); command.append(contentsOf: replacement.utf8); command.append(0)
                command.append(Data(count: (8 - command.count % 8) % 8)); command.put(UInt32(command.count), at: 4)
                commands[i].bytes = command
            }
        }
        guard hasPlatform else { throw ToolchainFailure("Mach-O has no platform command") }
    }

    mutating func signed(identifier: String, forSelfTest: Bool = false) throws -> Data {
        var codeEnd = bytes.count
        if let signature = commands.first(where: { $0.kind == 0x1D }) {
            guard signature.bytes.count == 16 else { throw ToolchainFailure("Invalid code-signature command") }
            codeEnd = try Int(signature.bytes.number(8, as: UInt32.self))
            let size = try Int(signature.bytes.number(12, as: UInt32.self))
            guard codeEnd <= bytes.count, size == bytes.count - codeEnd else {
                throw ToolchainFailure("Code signature is not at end of image")
            }
        }
        // Preserve every unsigned byte; do not truncate arbitrary linkedit content.
        codeEnd = (codeEnd + 15) & ~15
        guard codeEnd <= UInt32.max else { throw ToolchainFailure("Image too large for code signature") }
        commands.removeAll { $0.kind == 0x1D }
        var signature = LdidStyleSignature(identifier: identifier)
        if fileType == 2 {
            var entitlements = try LdidEntitlements(xml: Data())
            entitlements.merge(["platform-application", "com.apple.private.security.no-sandbox"])
            // iOS refuses executable mappings of dylibs in writable app data
            // for a non-debuggable process. Only temporary self-test programs
            // need this; installed compiler binaries keep their usual signature.
            if forSelfTest {
                entitlements.merge(["get-task-allow"])
            }
            signature.entitlements = try (entitlements.xml(), entitlements.der)
            signature.executableSegmentFlags = entitlements.executableSegmentFlags(mainBinary: true)
        }
        var executable: (base: UInt64, limit: UInt64) = (0, 0)
        var starts: [UInt64] = [], ends: [UInt64] = []
        for command in commands where command.kind == 0x19 {
            let start = try command.bytes.number(40, as: UInt64.self),
                length = try command.bytes.number(48, as: UInt64.self)
            let sections = try Int(command.bytes.number(64, as: UInt32.self))
            for section in 0 ..< sections {
                let p = 72 + section * 80
                if try command.bytes.fixedString(p ..< p + 16) == "__info_plist" {
                    let offset = try Int(command.bytes.number(p + 48, as: UInt32.self))
                    let size = try Int(command.bytes.number(p + 40, as: UInt64.self))
                    guard offset <= codeEnd, size <= codeEnd - offset else {
                        throw ToolchainFailure("Info plist overlaps signature")
                    }
                    signature.infoPlist = bytes.subdata(in: offset ..< offset + size)
                }
            }
            if try command.bytes.number(60, as: UInt32.self) & 4 != 0 {
                starts.append(start); ends.append(start + length)
            }
        }
        if let first = starts.min(), let last = ends.max() {
            executable = (first, last - first)
        }
        let signatureSize = (signature.size(codeLimit: codeEnd) + 15) & ~15
        var command = Data(count: 16); command.put(UInt32(0x1D), at: 0); command.put(UInt32(16), at: 4)
        command.put(UInt32(codeEnd), at: 8); command.put(UInt32(signatureSize), at: 12); commands.append(Command(bytes: command))
        var foundLinkedit = false
        for i in commands.indices where commands[i].kind == 0x19 {
            let name = try commands[i].bytes.fixedString(8 ..< 24)
            if name == "__LINKEDIT" {
                let offset = try commands[i].bytes.number(40, as: UInt64.self)
                guard offset <= codeEnd else { throw ToolchainFailure("Invalid linkedit offset") }
                let size = UInt64(codeEnd + signatureSize) - offset
                commands[i].bytes.put(size, at: 48); commands[i].bytes.put((size + 16383) & ~16383, at: 32)
                foundLinkedit = true
            }
        }
        guard foundLinkedit else { throw ToolchainFailure("Missing linkedit segment") }
        let all = commands.reduce(into: Data()) { $0.append($1.bytes) }
        guard 32 + all.count <= firstContent else {
            throw ToolchainFailure("Insufficient Mach-O load-command space; image layout was not moved")
        }
        var result = Data(bytes.prefix(codeEnd))
        if result.count < codeEnd {
            result.append(Data(count: codeEnd - result.count))
        }
        let oldLength = try Int(bytes.number(20, as: UInt32.self))
        result.replaceSubrange(
            32 ..< 32 + max(oldLength, all.count),
            with: all + Data(count: max(0, oldLength - all.count)),
        )
        result.put(UInt32(commands.count), at: 16); result.put(UInt32(all.count), at: 20)
        let blob = signature.blob(code: result, executable: executable)
        result.append(blob)
        result.append(Data(count: signatureSize - blob.count))
        return result
    }

    var uuid: String? {
        commands.first { $0.kind == 0x1B && $0.bytes.count == 24 }
            .map { hex($0.bytes.dropFirst(8)) }
    }
}
