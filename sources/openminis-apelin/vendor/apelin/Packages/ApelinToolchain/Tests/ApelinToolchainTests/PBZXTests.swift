@testable import ApelinToolchain
import Compression
import Foundation
import Testing

/// The Payload's pbzx stream decoded several chunks at a time gives exactly
/// the bytes a one-at-a-time decode does, whatever the window, and a damaged
/// or truncated chunk still fails.
struct PBZXTests {
    private func xz(_ data: Data) -> Data {
        var output = Data(count: data.count + 4096)
        let count = output.withUnsafeMutableBytes { out in data.withUnsafeBytes { input in
            compression_encode_buffer(
                out.bindMemory(to: UInt8.self).baseAddress!, out.count,
                input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                nil, COMPRESSION_LZMA,
            )
        } }
        precondition(count > 0)
        return output.prefix(count)
    }

    private func be(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    /// Seven chunks, one stored as is, the last short.
    private func stream() -> (pbzx: Data, plain: Data) {
        var plain = Data(), pbzx = Data("pbzx".utf8) + be(4096)
        for index in 0 ..< 7 {
            let size = index == 6 ? 1000 : 4096
            let chunk = Data((0 ..< size).map { UInt8(truncatingIfNeeded: ($0 / (index + 1)) &* 13 &+ index) })
            plain += chunk
            let packed = index == 3 ? chunk : xz(chunk)
            pbzx += be(UInt64(size)) + be(UInt64(packed.count)) + packed
        }
        return (pbzx, plain)
    }

    private func decode(_ pbzx: Data, window: Int, count: Int) throws -> Data {
        let file = URL(fileURLWithPath: "/private/tmp/apelin-pbzx-" + UUID().uuidString)
        try pbzx.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let reader = try BinaryReader(file)
        let stream = try PBZXReader(reader: reader, end: UInt64(pbzx.count), window: window)
        var result = Data()
        while result.count < count {
            result += try stream.read(min(777, count - result.count))
        }
        return result
    }

    @Test func `every window gives the same bytes`() throws {
        let (pbzx, plain) = stream()
        for window in [1, 2, 3, 4, 8] {
            #expect(try decode(pbzx, window: window, count: plain.count) == plain)
        }
    }

    /// The packaging digests and the install check map files on several
    /// cores: answers in order, and the first failing item's error.
    @Test func `concurrent map keeps order and the first error`() throws {
        struct Failure: Error, Equatable { let index: Int }
        #expect(try concurrentMap(Array(0 ..< 1000)) { $0 * 2 } == (0 ..< 1000).map { $0 * 2 })
        #expect(throws: Failure(index: 37)) {
            _ = try concurrentMap(Array(0 ..< 1000)) { value -> Int in
                if value == 37 || value == 900 {
                    throw Failure(index: value)
                }
                return value
            }
        }
    }

    @Test func `damaged or truncated streams fail`() throws {
        let (pbzx, plain) = stream()
        var damaged = pbzx
        damaged[damaged.count - 20] ^= 0xFF
        for window in [1, 4] {
            #expect(throws: (any Error).self) { try decode(damaged, window: window, count: plain.count) }
            #expect(throws: (any Error).self) { try decode(pbzx, window: window, count: plain.count + 1) }
        }
    }
}
