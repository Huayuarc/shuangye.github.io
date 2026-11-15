import CryptoKit
import Darwin
import Foundation

public enum ToolchainStage: String, Codable, Sendable {
    case downloading, extracting, adapting, packaging, installing, validating, ready
}

public struct ToolchainProgress: Sendable {
    public let stage: ToolchainStage
    public let completedBytes: Int64
    public let totalBytes: Int64?
    public let detail: String
}

public typealias ToolchainProgressHandler = @Sendable (ToolchainProgress) -> Void

public enum ToolchainComponent: String, Codable, Sendable { case base, swift }

public struct ToolchainSource: Codable, Equatable, Sendable {
    public let productID: String
    public let version: String
    public let url: URL
    public let size: Int64
    public let upstreamDigest: String?
    public let upstreamDigestAlgorithm: String?
    public init(
        productID: String,
        version: String,
        url: URL,
        size: Int64,
        upstreamDigest: String? = nil,
        upstreamDigestAlgorithm: String? = nil,
    ) {
        self.productID = productID; self.version = version; self.url = url; self.size = size
        self.upstreamDigest = upstreamDigest; self.upstreamDigestAlgorithm = upstreamDigestAlgorithm
    }
}

public struct ToolchainManifest: Codable, Sendable {
    public let id: String
    public let source: ToolchainSource
    public let sourceSHA256: String
    public let retargetSchemeVersion: Int
    /// The Mach-O deployment value written by the retargeter. Component host
    /// requirements (especially Swift's) are recorded separately below.
    public let minimumOS: String
    public let components: Set<ToolchainComponent>
    /// Relative paths only. The environment worker obtains the install root from hello.
    public let files: [String: String]
    /// Relative links the tree keeps as links, path → relative target, each
    /// resolving to one of `files` or a folder of them: `usr/bin/swiftc` →
    /// `swift-frontend`, `usr/lib/swift/clang` → `../clang/21`.
    public var links: [String: String]?
    public var stage: ToolchainStage
    public var selfTests: [ToolchainTestResult]
    /// The newest iPhoneOS SDK the tools read (`CommandLineToolsRelease.newestSDK`),
    /// carried in the tree so the toolchain says it itself.
    public var newestSDK: String?
    public var swiftSupport: SwiftToolchainSupport?
    public var clangModuleCPUFeatures: [String]?
    public var compatibility: ReleaseCompatibility?
    public var installRelativePath: String {
        "usr/lib/apelin/toolchains/" + id
    }
}

public struct ToolchainTestResult: Codable, Sendable {
    public let language: String
    public let architecture: String
    public let passed: Bool
    public let detail: String
    public let seconds: Double
}

struct ToolchainFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

/// Lowercase hex, the spelling every digest here is stored and compared in.
func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func sha256(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
}

func digestFile(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var h = SHA256()
    while let data = try autoreleasepool(invoking: { try file.read(upToCount: 1024 * 1024) }), !data.isEmpty {
        try Task.checkCancellation()
        h.update(data: data)
    }
    return hex(h.finalize())
}

/// `body` for every item on up to four cores, answers in the items' order;
/// the error thrown is the first failing item's, in that order. Each call is
/// independent (a file's digest), so the answers are what a loop gives.
func concurrentMap<T, R>(_ items: [T], _ body: (T) throws -> R) throws -> [R] {
    var values = [Result<R, Error>?](repeating: nil, count: items.count)
    let workers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount), max(1, items.count))
    try Task.checkCancellation()
    values.withUnsafeMutableBufferPointer { buffer in
        let base = UncheckedPointer(base: buffer.baseAddress)
        withoutActuallyEscaping(body) { body in
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                var index = worker
                while index < items.count {
                    base.base![index] = Result { try body(items[index]) }
                    index += workers
                }
            }
        }
    }
    try Task.checkCancellation()
    return try values.map { try $0!.get() }
}

private struct UncheckedPointer<T>: @unchecked Sendable { let base: UnsafeMutablePointer<T>? }

func writeJSON(_ value: some Encodable, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

func canonical(_ url: URL) throws -> URL {
    guard !url.path.utf8.contains(0), let path = realpath(url.path, nil) else {
        throw ToolchainFailure("Cannot resolve filesystem path")
    }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path))
}

func contained(_ path: URL, in root: URL) -> Bool {
    path.pathComponents.starts(with: root.pathComponents)
}

func directory(_ url: URL) throws {
    guard !url.path.utf8.contains(0) else { throw ToolchainFailure("NUL in filesystem path") }
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700],
    )
}

extension Data {
    func number<T: FixedWidthInteger>(_ offset: Int, as _: T.Type = T.self, big: Bool = false) throws -> T {
        guard offset >= 0, offset <= count, MemoryLayout<T>.size <= count - offset else {
            throw ToolchainFailure("Truncated binary field")
        }
        let value = withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        return big ? T(bigEndian: value) : T(littleEndian: value)
    }

    mutating func put(_ value: some FixedWidthInteger, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange(offset ..< offset + $0.count, with: $0) }
    }

    func fixedString(_ range: Range<Int>) throws -> String {
        guard range.lowerBound >= 0, range.upperBound <= count else {
            throw ToolchainFailure("Truncated fixed-width string")
        }
        let bytes = self[range].prefix { $0 != 0 }
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw ToolchainFailure("Invalid fixed-width string")
        }
        return value
    }

    func cString(_ range: Range<Int>) throws -> String {
        guard
            range.lowerBound >= 0,
            range.upperBound <= count,
            let end = self[range].firstIndex(of: 0),
            let result = String(data: self[range.lowerBound ..< end], encoding: .utf8)
        else {
            throw ToolchainFailure("Invalid binary string")
        }
        return result
    }
}
