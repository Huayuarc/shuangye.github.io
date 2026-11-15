// The slice handling is Irisin's (MIT, OwnGoal Studio, see LICENSE beside
// this file): Packages/IrisinKit/Sources/IrisinAdapter/MachO/MachOBinary.swift,
// `rewritten(identifier:)` and `rewrite(_:identifier:)`. Changed here: the load
// commands are read by hand with bounds checks instead of through MachOKit,
// no install name or rpath is rewritten (that is roothide's patcher, not a
// build), and the entitlements are the product's own file as `ldid -S<file>`
// embeds it, not the old signature's merged with roothide's.

import Foundation

/// Why a Mach-O cannot be signed.
public enum CodeSignFailure: Error, Equatable, Sendable {
    /// Not a library, a bundle or a program: an object file, a dSYM.
    case notCode
    /// A header, an architecture, a load command or the old signature
    /// points outside the file.
    case malformed
    /// Entitlements ldid would not carry into DER as they are read here: a
    /// binary plist, a date, a real, XML libplist reads its own way.
    case unsupportedEntitlements
    /// A slice that is not 64-bit little-endian.
    case unsupportedSlice
    /// The code-signature load command does not fit in front of the first section.
    case noRoom
}

/// Signs a Mach-O the way `ldid -Hsha256 -S` (or `-S<entitlements>`) does,
/// every slice of a fat file, without running ldid: a SuperBlob holding a
/// SHA-256 code directory, the designated requirement ldid derives from the
/// identifier, and the entitlements as XML and as DER when there are any. No
/// CMS blob. Signing is the last thing that touches a product; anything
/// after it breaks the signature.
public enum CodeSigner {
    public struct Options: Sendable {
        /// What the signature names the code: by ldid's convention the file name.
        public var identifier: String
        /// The entitlements file, read as libplist reads it and written again as ldid writes it; nil for none.
        public var entitlements: Data?

        public init(identifier: String, entitlements: Data? = nil) {
            self.identifier = identifier
            self.entitlements = entitlements
        }
    }

    public static func sign(_ data: Data, options: Options) throws -> Data {
        guard data.count >= 8 else { throw CodeSignFailure.malformed }
        let magic: UInt32 = data.integer(at: 0)
        switch magic {
        case MachConstant.magic64:
            try checkType(data, at: 0)
            try validate(data, 0 ..< data.count)
            return try signSlice(data, fatAlignment: nil, options: options)
        case MachConstant.fatCigam:
            let count = Int((data.integer(at: 4) as UInt32).byteSwapped)
            guard (1 ..< 20).contains(count), 8 + count * 20 <= data.count else { throw CodeSignFailure.malformed }
            var arches: [FatArch] = []
            for index in 0 ..< count {
                let base = 8 + index * 20
                let arch = FatArch(
                    cputype: data.bigEndianInteger(at: base),
                    cpusubtype: data.bigEndianInteger(at: base + 4),
                    offset: data.bigEndianInteger(at: base + 8),
                    size: data.bigEndianInteger(at: base + 12),
                    align: data.bigEndianInteger(at: base + 16),
                )
                guard arch.align <= 15, Int(arch.offset) + Int(arch.size) <= data.count else {
                    throw CodeSignFailure.malformed
                }
                arches.append(arch)
            }
            for arch in arches {
                try checkType(data, at: Int(arch.offset))
            }
            for arch in arches {
                try validate(data, Int(arch.offset) ..< Int(arch.offset) + Int(arch.size))
            }
            let images = try arches.map { arch in
                try signSlice(
                    data[Int(arch.offset) ..< Int(arch.offset) + Int(arch.size)],
                    fatAlignment: arch.align,
                    options: options,
                )
            }
            // ldid lays the slices out again, each on its own alignment
            var header = Data()
            header.append(bigEndian: MachConstant.fatMagic)
            header.append(bigEndian: UInt32(arches.count))
            var body = Data()
            let bodyStart = 8 + arches.count * 20
            for (arch, image) in zip(arches, images) {
                let offset = (bodyStart + body.count).aligned(to: 1 << Int(arch.align))
                body.append(Data(count: offset - bodyStart - body.count))
                body.append(image)
                guard let start = UInt32(exactly: offset), let size = UInt32(exactly: image.count) else {
                    throw CodeSignFailure.malformed
                }
                for field in [arch.cputype, arch.cpusubtype, start, size, arch.align] {
                    header.append(bigEndian: field)
                }
            }
            return header + body
        case MachConstant.magic32, MachConstant.cigam32, MachConstant.cigam64, MachConstant.fatCigam64:
            throw CodeSignFailure.unsupportedSlice
        default:
            throw CodeSignFailure.notCode
        }
    }

    public static func sign(fileAt url: URL, options: Options) throws {
        let signed = try sign(Data(contentsOf: url), options: options)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).signing-\(UUID().uuidString.prefix(8))")
        try signed.write(to: temporary)
        var info = stat()
        if stat(url.path, &info) == 0 {
            chmod(temporary.path, info.st_mode & 0o7777)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    // MARK: One slice

    private struct FatArch {
        var cputype: UInt32
        var cpusubtype: UInt32
        var offset: UInt32
        var size: UInt32
        var align: UInt32
    }

    private struct Segment {
        /// Offset among the load commands.
        var commandOffset: Int
        var name: String
        var fileoff: UInt64
        var filesize: UInt64
        var initprot: UInt32
        var sections: [(name: String, offset: UInt32, size: UInt64)]
    }

    private static func signSlice(_ bytes: Data, fatAlignment: UInt32?, options: Options) throws -> Data {
        let headerSize = 32
        var image = Data(bytes)
        let filetype: UInt32 = image.integer(at: 12)
        let cputype: UInt32 = image.integer(at: 4)
        let ncmds: UInt32 = image.integer(at: 16)
        let commandsSize = Int(image.integer(at: 20) as UInt32)

        var signature: (commandOffset: Int, dataoff: UInt32, datasize: UInt32)?
        var linkedits: [Segment] = []
        var strings: UInt64?
        var executable: (start: UInt64, end: UInt64) = (.max, 0)
        var infoPlist: (offset: UInt64, size: UInt64)?
        var sectionOffsets: [UInt64] = []
        var sectionlessContent: [UInt64] = []

        var cursor = 0
        for _ in 0 ..< ncmds {
            let start = headerSize + cursor
            let command: UInt32 = image.integer(at: start)
            let length = Int(image.integer(at: start + 4) as UInt32)
            switch command {
            case MachConstant.codeSignature:
                signature = (cursor, image.integer(at: start + 8), image.integer(at: start + 12))
            case MachConstant.symtab:
                let offset: UInt32 = image.integer(at: start + 16)
                let size: UInt32 = image.integer(at: start + 20)
                strings = offset == 0 && size == 0 ? nil : UInt64(offset) + UInt64(size)
            case MachConstant.segment64:
                let nameBytes = image[start + 8 ..< start + 24].prefix { $0 != 0 }
                var segment = Segment(
                    commandOffset: cursor,
                    name: String(decoding: nameBytes, as: UTF8.self),
                    fileoff: image.integer(at: start + 40),
                    filesize: image.integer(at: start + 48),
                    initprot: image.integer(at: start + 60),
                    sections: [],
                )
                let count = Int(image.integer(at: start + 64) as UInt32)
                for index in 0 ..< count {
                    let section = start + 72 + index * 80
                    let sectionName = String(
                        decoding: image[section ..< section + 16].prefix { $0 != 0 },
                        as: UTF8.self,
                    )
                    let offset: UInt32 = image.integer(at: section + 48)
                    segment.sections.append((sectionName, offset, image.integer(at: section + 40)))
                    sectionOffsets.append(UInt64(offset))
                }
                if segment.name == "__LINKEDIT" {
                    linkedits.append(segment)
                }
                if segment.initprot & 0x4 != 0 {
                    executable = (
                        min(executable.start, segment.fileoff),
                        max(executable.end, segment.fileoff &+ segment.filesize),
                    )
                }
                if segment.name == "__TEXT" {
                    for section in segment.sections where section.name == "__info_plist" {
                        infoPlist = (segment.fileoff &+ UInt64(section.offset), section.size)
                    }
                }
                if count == 0, segment.filesize > 0 {
                    sectionlessContent.append(segment.fileoff)
                }
            default:
                break
            }
            cursor += length
        }
        guard !linkedits.isEmpty else { throw CodeSignFailure.malformed }

        var commands = Data(image[headerSize ..< headerSize + commandsSize])
        // the old signature begins where the code ended; a file that never
        // had one gets the command, as ldid adds it, after all the others
        let oldSignature: Int
        let signatureCommand: Int
        if let signature {
            oldSignature = Int(signature.dataoff)
            guard oldSignature <= image.count, oldSignature + Int(signature.datasize) == image.count else {
                throw CodeSignFailure.malformed
            }
            signatureCommand = headerSize + signature.commandOffset
        } else {
            oldSignature = image.count
            signatureCommand = headerSize + commands.count
            var command = Data(count: 16)
            command.store(MachConstant.codeSignature, at: 0)
            command.store(UInt32(16), at: 4)
            commands.append(command)
            image.store(ncmds + 1, at: 16)
        }
        // ldid ends the code at the end of the string table, which it adds
        // up in 32 bits and asserts is not past the old signature
        var codeEnd = oldSignature
        if let strings {
            guard strings <= UInt32.max, strings <= UInt64(codeEnd) else { throw CodeSignFailure.malformed }
            codeEnd = Int(strings)
        }
        let firstSection = (sectionOffsets + sectionlessContent).filter { $0 > 0 }.min() ?? 0
        guard UInt64(headerSize + commands.count) <= firstSection, firstSection <= UInt64(codeEnd) else {
            throw CodeSignFailure.noRoom
        }
        image.replaceSubrange(headerSize ..< headerSize + commands.count, with: commands)
        image.store(UInt32(commands.count), at: 20)

        var signer = LdidStyleSignature(identifier: options.identifier)
        let mainBinary = filetype == MachConstant.execute
        if let entitlements = options.entitlements, !entitlements.isEmpty {
            // ldid reads the file with libplist and writes it again, keys in
            // the order they were written: what `xml()` writes
            let parsed = try LdidEntitlements(xml: entitlements)
            signer.entitlements = try (parsed.xml(), parsed.der)
            signer.executableSegmentFlags = parsed.executableSegmentFlags(mainBinary: mainBinary)
        } else {
            signer.executableSegmentFlags = mainBinary ? 1 : 0
        }
        if let infoPlist {
            let start = Int(UInt32(truncatingIfNeeded: infoPlist.offset))
            guard start >= headerSize + commands.count, start <= image.count, infoPlist.size <= UInt64(image.count - start) else {
                throw CodeSignFailure.malformed
            }
            signer.infoPlist = image.subdata(in: start ..< start + Int(infoPlist.size))
        }

        let codeLimit = codeEnd.aligned(to: 16)
        let signatureSize = signer.size(codeLimit: codeLimit).aligned(to: 16)
        image = image.prefix(codeEnd) + Data(count: codeLimit - codeEnd)
        image.store(UInt32(codeLimit), at: signatureCommand + 8)
        image.store(UInt32(signatureSize), at: signatureCommand + 12)
        // ldid rounds the segment to the slice's alignment in the fat header,
        // or in a thin file to what it takes its CPU's page to be
        let align = if let fatAlignment {
            Int(fatAlignment)
        } else {
            switch cputype {
            case 12, 0x0100_000C, 0x0200_000C: 14 // ARM, ARM64, ARM64_32
            case 7, 0x0100_0007, 18, 0x0100_0012: 12 // x86, x86_64, PowerPC
            default: 0
            }
        }
        for linkedit in linkedits {
            let end = UInt64(codeLimit + signatureSize)
            guard linkedit.fileoff < end else { throw CodeSignFailure.malformed }
            let size = Int(end - linkedit.fileoff)
            image.store(UInt64(size.aligned(to: 1 << align)), at: headerSize + linkedit.commandOffset + 32)
            image.store(UInt64(size), at: headerSize + linkedit.commandOffset + 48)
        }

        let blob = signer.blob(code: image, executable: (executable.start, executable.end &- executable.start))
        return image + blob + Data(count: signatureSize - blob.count)
    }

    /// `filetype` sits at the same offset in either header.
    private static func checkType(_ data: Data, at offset: Int) throws {
        guard offset + 16 <= data.count else { throw CodeSignFailure.malformed }
        let magic: UInt32 = data.integer(at: offset)
        guard magic == MachConstant.magic32 || magic == MachConstant.magic64 else { return }
        let type: UInt32 = data.integer(at: offset + 12)
        guard [MachConstant.dylib, MachConstant.bundle, MachConstant.execute].contains(type) else {
            throw CodeSignFailure.notCode
        }
    }

    /// A 64-bit header, and load commands inside the space it gives them.
    private static func validate(_ data: Data, _ range: Range<Int>) throws {
        let headerSize = 32
        guard range.count >= headerSize else { throw CodeSignFailure.malformed }
        guard data.integer(at: range.lowerBound) as UInt32 == MachConstant.magic64 else {
            throw CodeSignFailure.unsupportedSlice
        }
        let count = Int(data.integer(at: range.lowerBound + 16) as UInt32)
        let size = Int(data.integer(at: range.lowerBound + 20) as UInt32)
        guard headerSize + size <= range.count else { throw CodeSignFailure.malformed }
        var cursor = 0
        for _ in 0 ..< count {
            guard cursor + 8 <= size else { throw CodeSignFailure.malformed }
            let start = range.lowerBound + headerSize + cursor
            let command: UInt32 = data.integer(at: start)
            let length = Int(data.integer(at: start + 4) as UInt32)
            let least = switch command {
            case MachConstant.segment64: 72
            case MachConstant.codeSignature: 16
            case MachConstant.symtab: 24
            default: 8
            }
            guard length >= least, length % 8 == 0, cursor + length <= size else { throw CodeSignFailure.malformed }
            if command == MachConstant.segment64 {
                let sections = Int(data.integer(at: start + 64) as UInt32)
                guard least + sections * 80 <= length else { throw CodeSignFailure.malformed }
                let offset: UInt64 = data.integer(at: start + 40)
                let segmentSize: UInt64 = data.integer(at: start + 48)
                guard offset <= UInt64(range.count), segmentSize <= UInt64(range.count) - offset else {
                    throw CodeSignFailure.malformed
                }
            }
            cursor += length
        }
    }
}

enum MachConstant {
    static let magic32: UInt32 = 0xFEED_FACE
    static let magic64: UInt32 = 0xFEED_FACF
    static let cigam32: UInt32 = 0xCEFA_EDFE
    static let cigam64: UInt32 = 0xCFFA_EDFE
    static let fatMagic: UInt32 = 0xCAFE_BABE
    static let fatCigam: UInt32 = 0xBEBA_FECA
    static let fatCigam64: UInt32 = 0xBFBA_FECA
    static let execute: UInt32 = 0x2
    static let dylib: UInt32 = 0x6
    static let bundle: UInt32 = 0x8
    static let segment64: UInt32 = 0x19
    static let symtab: UInt32 = 0x2
    static let codeSignature: UInt32 = 0x1D
}

private extension Int {
    func aligned(to boundary: Int) -> Int {
        (self + boundary - 1) / boundary * boundary
    }
}

private extension Data {
    /// A Mach-O field, little-endian as every slice that gets here is.
    func integer<T: FixedWidthInteger>(at offset: Int) -> T {
        T(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) })
    }

    /// A fat header or code signing field, big-endian.
    func bigEndianInteger<T: FixedWidthInteger>(at offset: Int) -> T {
        T(bigEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) })
    }

    mutating func store(_ value: some FixedWidthInteger, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange(offset ..< offset + $0.count, with: $0) }
    }

    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
