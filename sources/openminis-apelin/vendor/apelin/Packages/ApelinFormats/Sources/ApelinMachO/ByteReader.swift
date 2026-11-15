// Copied from Fila (MIT, OwnGoal Studio): FilaFormats/DescriptorReader.swift.
// Changed here: the reader also stands over an in-memory buffer or a file it
// opened itself, so a build step that just wrote a binary can read it back
// without handing a descriptor around. The descriptor path is unchanged.

import Foundation

/// Positional reads over a descriptor, a file, or a buffer.
///
/// Every descriptor read is `pread(2)`, never `lseek` + `read`. A descriptor
/// may have arrived over XPC and this process has no idea what else holds a
/// reference to the same open file description; moving the shared file offset
/// would corrupt whoever else is reading it. It also means a reader is a value
/// with no mutable state, so several parsers can hold the same one.
public struct ByteReader: Sendable {
    private enum Source: Sendable {
        /// A descriptor the caller owns and closes.
        case borrowed(Int32)
        /// A descriptor this reader opened and closes when the last copy goes.
        case owned(OwnedDescriptor)
        case memory(Data)
    }

    private let source: Source

    /// `st_size` as of construction, or the buffer's length. A file on a live
    /// filesystem can be truncated underneath a reader, so reads past the end
    /// come back short rather than failing.
    public let byteCount: Int64

    /// Reads through `descriptor`, which must be a regular file. The caller
    /// keeps ownership: the reader never closes it, so it must stay open for
    /// as long as the reader, or anything built on it, is used.
    public init(descriptor: Int32) throws {
        byteCount = try Self.regularFileSize(descriptor)
        source = .borrowed(descriptor)
    }

    /// Opens `path` read-only, refusing anything that is not a regular file
    /// once opened. The descriptor is closed when the last copy of the reader
    /// is released.
    public init(contentsOfFile path: String) throws {
        guard !path.utf8.contains(0) else { throw FormatFailure.system(errno: EINVAL) }
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw FormatFailure.system(errno: errno) }
        let owned = OwnedDescriptor(descriptor)
        byteCount = try Self.regularFileSize(descriptor)
        source = .owned(owned)
    }

    /// Reads from bytes already in memory.
    public init(data: Data) {
        source = .memory(data)
        byteCount = Int64(data.count)
    }

    private static func regularFileSize(_ descriptor: Int32) throws -> Int64 {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw FormatFailure.system(errno: errno) }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else {
            throw FormatFailure.system(errno: EINVAL)
        }
        return Int64(status.st_size)
    }

    /// Up to `count` bytes at `offset`. Short at the end of the file.
    public func readUpTo(at offset: Int64, count: Int) throws -> Data {
        guard count > 0, offset >= 0, offset < byteCount else { return Data() }
        let count = min(count, Int(byteCount - offset))
        switch source {
        case let .memory(data):
            let start = data.startIndex + Int(offset)
            return data.subdata(in: start ..< start + count)
        case let .borrowed(descriptor):
            return try Self.pread(descriptor, at: offset, count: count)
        case let .owned(owned):
            return try Self.pread(owned.descriptor, at: offset, count: count)
        }
    }

    /// Exactly `count` bytes, or `damaged`. Used wherever a structure's own
    /// header said the bytes are there — if they are not, the file is lying
    /// about its shape and no amount of parsing recovers it.
    public func read(at offset: Int64, count: Int) throws -> Data {
        let data = try readUpTo(at: offset, count: count)
        guard data.count == count else {
            throw FormatFailure.damaged("it is truncated")
        }
        return data
    }

    private static func pread(_ descriptor: Int32, at offset: Int64, count: Int) throws -> Data {
        var buffer = Data(count: count)
        var filled = 0
        while filled < count {
            let got: Int = buffer.withUnsafeMutableBytes { raw in
                Foundation.pread(
                    descriptor,
                    raw.baseAddress!.advanced(by: filled),
                    count - filled,
                    off_t(offset) + off_t(filled),
                )
            }
            if got < 0 {
                if errno == EINTR {
                    continue
                }
                throw FormatFailure.system(errno: errno)
            }
            if got == 0 {
                break
            }
            filled += got
        }
        buffer.removeSubrange(filled...)
        return buffer
    }
}

/// A descriptor closed when the last reference goes. Immutable after init, so
/// sharing it between copies of a reader on several threads is safe.
final class OwnedDescriptor: Sendable {
    let descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }
}

extension Data {
    /// Reads a fixed-width integer at a byte offset from the start of this
    /// value, throwing rather than trapping when the bytes are not there.
    ///
    /// Mach-O headers are untrusted input and their length fields routinely
    /// point past the end of a truncated file. A subscript would trap; a slice
    /// would silently read whatever came after. This throws.
    func littleEndian<T: FixedWidthInteger>(at offset: Int) throws -> T {
        try T(littleEndian: load(at: offset))
    }

    func bigEndian<T: FixedWidthInteger>(at offset: Int) throws -> T {
        try T(bigEndian: load(at: offset))
    }

    /// The same read with the byte order decided at run time: the header says
    /// which order the rest of the file is in, so it cannot be a choice
    /// between two call sites.
    func integer<T: FixedWidthInteger>(at offset: Int, bigEndian isBigEndian: Bool) throws -> T {
        if isBigEndian {
            return try bigEndian(at: offset)
        }
        return try littleEndian(at: offset)
    }

    private func load<T: FixedWidthInteger>(at offset: Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset <= count - size else {
            throw FormatFailure.damaged("it is truncated")
        }
        var value = T.zero
        _ = Swift.withUnsafeMutableBytes(of: &value) { destination in
            copyBytes(to: destination, from: (startIndex + offset) ..< (startIndex + offset + size))
        }
        return value
    }

    /// A fixed-width field holding a NUL-padded C string, as a Mach-O load
    /// command does. Bytes after the first NUL are ignored, and invalid UTF-8
    /// is replaced rather than rejected: a dylib with a mangled name still has
    /// to appear in the listing.
    func string(at offset: Int, count length: Int) throws -> String {
        guard offset >= 0, length >= 0, offset <= count - length else {
            throw FormatFailure.damaged("a name inside it is truncated")
        }
        let start = startIndex + offset
        return String(decoding: self[start ..< start + length].prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
