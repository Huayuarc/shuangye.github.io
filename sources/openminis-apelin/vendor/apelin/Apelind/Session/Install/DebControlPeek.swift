import Compression
import Darwin
import Foundation

/// Reads `Package`, `Version` and `Architecture` out of a staged `.deb`, so
/// the host knows what it is about to hand irisind before it does — the
/// managed-package rules are checked against the package itself, not what a
/// build or a request says it is — and its `Conflicts`, `Breaks` and
/// `Replaces`, which explain an install irisind refused.
///
/// System code only: the ar container, the control member uncompressed, as
/// gzip (raw deflate through libcompression) or as xz (libcompression's LZMA
/// is the xz container), and a ustar walk to `./control`. A control member in
/// another compression answers `unreadable`, and the caller falls back to the
/// build's own record and checks irisind's report against it.
enum DebControlPeek {
    struct Control: Equatable {
        var packageID: String
        var version: String
        var architecture: String?
        var conflicts: [Relation] = []
        var breaks: [Relation] = []
        var replaces: [Relation] = []
    }

    /// One package a relation field names, each alternative of `a | b` on
    /// its own: `foo (<< 2.0)` is `foo` with constraint `<< 2.0`.
    struct Relation: Equatable {
        var package: String
        var constraint: String?
    }

    enum Failure: Error, Equatable {
        case notADebian
        case unreadable
    }

    /// Bigger control members than this are not a project's.
    static let maximumControlMember = 16 << 20

    static func read(descriptor: Int32) throws -> Control {
        var magic = [UInt8](repeating: 0, count: 8)
        guard pread(descriptor, &magic, 8, 0) == 8, magic == Array("!<arch>\n".utf8) else { throw Failure.notADebian }
        var offset: off_t = 8
        while true {
            var header = [UInt8](repeating: 0, count: 60)
            let count = pread(descriptor, &header, 60, offset)
            guard count == 60 else { throw Failure.notADebian }
            let name = String(decoding: header[0 ..< 16], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard let size = Int(String(decoding: header[48 ..< 58], as: UTF8.self).trimmingCharacters(in: .whitespaces)),
                  size >= 0
            else {
                throw Failure.notADebian
            }
            let body = offset + 60
            let member = name.hasSuffix("/") ? String(name.dropLast()) : name
            if member.hasPrefix("control.tar") {
                guard size <= maximumControlMember else { throw Failure.unreadable }
                var bytes = [UInt8](repeating: 0, count: size)
                guard pread(descriptor, &bytes, size, body) == size else { throw Failure.notADebian }
                let tar: [UInt8]
                switch member {
                case "control.tar": tar = bytes
                case "control.tar.gz": tar = try gunzip(bytes)
                case "control.tar.xz": tar = try decompress(bytes, algorithm: COMPRESSION_LZMA)
                default: throw Failure.unreadable
                }
                guard let text = controlFile(inTar: tar) else { throw Failure.unreadable }
                return try parse(text)
            }
            offset = body + off_t(size + (size & 1))
        }
    }

    static func parse(_ text: String) throws -> Control {
        var fields: [String: String] = [:]
        var last: String?
        for line in text.split(separator: "\n") {
            if line.first == " " || line.first == "\t" {
                // A relation field may be folded; nothing else read here is.
                if let last, Self.relationFields.contains(last) {
                    fields[last, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                last = nil
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            last = key
        }
        guard let package = fields["package"], !package.isEmpty,
              let version = fields["version"], !version.isEmpty
        else {
            throw Failure.unreadable
        }
        return Control(
            packageID: package,
            version: version,
            architecture: fields["architecture"],
            conflicts: relations(fields["conflicts"]),
            breaks: relations(fields["breaks"]),
            replaces: relations(fields["replaces"]),
        )
    }

    static let relationFields: Set<String> = ["conflicts", "breaks", "replaces"]

    /// `a (>= 1), b | c:any` as dpkg spells a relation field.
    static func relations(_ field: String?) -> [Relation] {
        guard let field else { return [] }
        return field.split(whereSeparator: { $0 == "," || $0 == "|" }).compactMap { alternative in
            var text = alternative.trimmingCharacters(in: .whitespaces)
            var constraint: String?
            if let open = text.firstIndex(of: "(") {
                constraint = text[text.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: " )"))
                text = text[..<open].trimmingCharacters(in: .whitespaces)
            }
            if let colon = text.firstIndex(of: ":") {
                text = String(text[..<colon])
            }
            guard !text.isEmpty else { return nil }
            return Relation(package: text.lowercased(), constraint: constraint?.isEmpty == false ? constraint : nil)
        }
    }

    /// The `./control` member of a ustar archive.
    static func controlFile(inTar tar: [UInt8]) -> String? {
        var offset = 0
        var longName: String?
        while offset + 512 <= tar.count {
            let header = tar[offset ..< offset + 512]
            if header.allSatisfy({ $0 == 0 }) {
                return nil
            }
            func field(_ start: Int, _ length: Int) -> String {
                let slice = tar[offset + start ..< offset + start + length]
                let end = slice.firstIndex(of: 0) ?? slice.endIndex
                return String(decoding: tar[slice.startIndex ..< end], as: UTF8.self)
            }
            // POSIX ustar splits long names into a prefix; GNU tar keeps
            // other fields there and spells long names as an `L` entry.
            let isPOSIX = Array(tar[offset + 257 ..< offset + 263]) == Array("ustar\0".utf8)
            let prefix = isPOSIX ? field(345, 155) : ""
            var name = longName ?? (prefix.isEmpty ? field(0, 100) : prefix + "/" + field(0, 100))
            longName = nil
            let sizeText = field(124, 12).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            guard let size = Int(sizeText, radix: 8), size >= 0 else { return nil }
            let type = tar[offset + 156]
            let dataStart = offset + 512
            guard dataStart + size <= tar.count else { return nil }
            if type == UInt8(ascii: "L") {
                let bytes = tar[dataStart ..< dataStart + size]
                longName = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            } else {
                while name.hasPrefix("./") {
                    name.removeFirst(2)
                }
                if name == "control", type == 0 || type == UInt8(ascii: "0") {
                    return String(decoding: tar[dataStart ..< dataStart + size], as: UTF8.self)
                }
            }
            offset = dataStart + ((size + 511) / 512) * 512
        }
        return nil
    }

    /// RFC 1952: skip the header, inflate the raw deflate stream.
    static func gunzip(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw Failure.unreadable
        }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { throw Failure.unreadable }
            index += 2 + (Int(bytes[index]) | (Int(bytes[index + 1]) << 8))
        }
        if flags & 0x08 != 0 {
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }; index += 1
        }
        if flags & 0x10 != 0 {
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }; index += 1
        }
        if flags & 0x02 != 0 {
            index += 2
        }
        guard index < bytes.count else { throw Failure.unreadable }
        return try decompress(Array(bytes[index...]), algorithm: COMPRESSION_ZLIB)
    }

    static func decompress(_ input: [UInt8], algorithm: compression_algorithm) throws -> [UInt8] {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK
        else {
            throw Failure.unreadable
        }
        defer { compression_stream_destroy(streamPointer) }
        let chunk = 1 << 16
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { output.deallocate() }
        var result: [UInt8] = []
        return try input.withUnsafeBufferPointer { source -> [UInt8] in
            streamPointer.pointee.src_ptr = source.baseAddress!
            streamPointer.pointee.src_size = source.count
            while true {
                streamPointer.pointee.dst_ptr = output
                streamPointer.pointee.dst_size = chunk
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                result.append(
                    contentsOf: UnsafeBufferPointer(start: output, count: chunk - streamPointer.pointee.dst_size),
                )
                guard result.count <= maximumControlMember * 4 else {
                    throw Failure.unreadable
                }
                switch status {
                case COMPRESSION_STATUS_OK:
                    // Out of output space, or input fully consumed without an end marker.
                    if streamPointer.pointee.src_size == 0, streamPointer.pointee.dst_size > 0 {
                        return result
                    }
                case COMPRESSION_STATUS_END:
                    return result
                default:
                    throw Failure.unreadable
                }
            }
        }
    }
}
