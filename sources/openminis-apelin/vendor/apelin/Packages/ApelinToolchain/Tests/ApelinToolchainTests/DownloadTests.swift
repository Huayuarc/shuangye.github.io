@testable import ApelinToolchain
import Foundation
import Testing

@Suite(.serialized) struct DownloadTests {
    @Test func `resumes verified prefix and restarts corruption`() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/apelin-toolchain-test-" + UUID().uuidString)
        try directory(root); defer { try? FileManager.default.removeItem(at: root) }
        let body = Data((0 ..< 128).map(UInt8.init))
        let source = try ToolchainSource(productID: "fixture", version: "27.0", url: #require(URL(string: "https://download.invalid/CLTools_Executables.pkg")), size: 128)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RangeFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for corrupt in [false, true] {
            let prefix = Data(body.prefix(8))
            try (corrupt ? Data(repeating: 255, count: 8) : prefix).write(to: root.appendingPathComponent("source.pkg"))
            try writeJSON(ResumableDownload.Receipt(source: source, validator: "fixture-v1", bytes: 8, prefixSHA256: sha256(prefix)), to: root.appendingPathComponent("download.json"))
            RangeFixture.expectedOffset = corrupt ? 0 : 8
            let file = try await ResumableDownload.run(source, in: root, progress: { _ in }, session: session)
            #expect(try Data(contentsOf: file) == body)
            let receipt = try JSONDecoder().decode(ResumableDownload.Receipt.self, from: Data(contentsOf: root.appendingPathComponent("download.json")))
            #expect(receipt.bytes == 128)
            #expect(receipt.prefixSHA256 == sha256(body))
        }
    }

    /// Several ranges in flight: the file is the body in order, every request
    /// after the first carries If-Range, the receipt names the whole file, and a
    /// validator that changes mid-download, or a range answered 200, restarts it.
    @Test func `parallel ranges assemble in order and refuse A changed package`() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/apelin-toolchain-test-" + UUID().uuidString)
        try directory(root); defer { try? FileManager.default.removeItem(at: root) }
        let body = Data((0 ..< 1000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let source = try ToolchainSource(productID: "fixture", version: "27.0", url: #require(URL(string: "https://ranges.invalid/CLTools_Executables.pkg")), size: Int64(body.count))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnyRangeFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        AnyRangeFixture.body = body
        for mode in [AnyRangeFixture.Mode.normal, .changeValidator, .fullAnswer] {
            AnyRangeFixture.mode = mode
            try? FileManager.default.removeItem(at: root.appendingPathComponent("download.json"))
            let attempt = { try await ResumableDownload.run(source, in: root, progress: { _ in }, session: session, rangeBytes: 64, parallelRanges: 4) }
            if mode == .normal {
                let file = try await attempt()
                #expect(try Data(contentsOf: file) == body)
                let receipt = try JSONDecoder().decode(ResumableDownload.Receipt.self, from: Data(contentsOf: root.appendingPathComponent("download.json")))
                #expect(receipt.bytes == Int64(body.count))
                #expect(receipt.prefixSHA256 == sha256(body))
                #expect(AnyRangeFixture.missingIfRange == 0)
            } else {
                await #expect(throws: (any Error).self) { _ = try await attempt() }
            }
        }
    }

    /// A later range refused outright (429, no validator) is not a changed
    /// package: the verified prefix and its receipt stay for the next attempt.
    @Test func `refused range keeps the verified prefix`() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/apelin-toolchain-test-" + UUID().uuidString)
        try directory(root); defer { try? FileManager.default.removeItem(at: root) }
        let body = Data((0 ..< 1000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let source = try ToolchainSource(productID: "fixture", version: "27.0", url: #require(URL(string: "https://ranges.invalid/CLTools_Executables.pkg")), size: Int64(body.count))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnyRangeFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        AnyRangeFixture.body = body
        AnyRangeFixture.mode = .throttled
        // One range of 64, then 64–319 side by side, the last of them refused.
        await #expect(throws: (any Error).self) {
            _ = try await ResumableDownload.run(source, in: root, progress: { _ in }, session: session, rangeBytes: 64, parallelRanges: 4)
        }
        let receipt = try JSONDecoder().decode(ResumableDownload.Receipt.self, from: Data(contentsOf: root.appendingPathComponent("download.json")))
        #expect(receipt.bytes == 256)
        #expect(receipt.prefixSHA256 == sha256(body.prefix(256)))
    }

    /// A range body longer than asked for is refused, not held.
    @Test func `overlong range is refused`() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/apelin-toolchain-test-" + UUID().uuidString)
        try directory(root); defer { try? FileManager.default.removeItem(at: root) }
        let source = try ToolchainSource(productID: "fixture", version: "27.0", url: #require(URL(string: "https://ranges.invalid/CLTools_Executables.pkg")), size: 256)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnyRangeFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        AnyRangeFixture.body = Data(repeating: 1, count: 256)
        AnyRangeFixture.mode = .overlong
        await #expect(throws: (any Error).self) {
            _ = try await ResumableDownload.run(source, in: root, progress: { _ in }, session: session, rangeBytes: 64, parallelRanges: 2)
        }
    }
}

/// Answers any `bytes=a-b` range of `body`, as the CDN does.
private final class AnyRangeFixture: URLProtocol, @unchecked Sendable {
    enum Mode { case normal, changeValidator, fullAnswer, overlong, throttled }
    // Set between fully awaited downloads only.
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var mode = Mode.normal
    nonisolated(unsafe) static var missingIfRange = 0
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "ranges.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.body
        guard let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
        let start = bounds[0], end = bounds[1]
        if start > 0 && request.value(forHTTPHeaderField: "If-Range") == nil {
            Self.missingIfRange += 1
        }
        let tag = Self.mode == .changeValidator && start >= 256 ? "fixture-v2" : "fixture-v1"
        if Self.mode == .fullAnswer, start > 0 {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": tag])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if Self.mode == .throttled, start >= 256 {
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes \(start)-\(end)/\(body.count)", "ETag": tag])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.mode == .overlong ? body : body.subdata(in: start ..< end + 1))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RangeFixture: URLProtocol, @unchecked Sendable {
    // This one test changes the expectation only between fully awaited requests.
    nonisolated(unsafe) static var expectedOffset = 0
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "download.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let start = Self.expectedOffset
        guard request.value(forHTTPHeaderField: "Range") == "bytes=\(start)-127",
              start == 0 || request.value(forHTTPHeaderField: "If-Range") == "fixture-v1"
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes \(start)-127/128", "ETag": "fixture-v1"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((start ..< 128).map(UInt8.init)))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
