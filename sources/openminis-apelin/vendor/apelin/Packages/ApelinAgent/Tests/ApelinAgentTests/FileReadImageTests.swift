@testable import ApelinAgent
import CoreGraphics
import Foundation
import ImageIO
import KWWKAgent
import KWWKAI
import Testing

/// file_read on an image: a picture the model can see, scaled down and
/// encoded again; every other file as before.
@Suite("file_read shows images")
struct FileReadImageTests {
    let home: TemporaryHome
    let runner: ToolRunner

    init() throws {
        home = try TemporaryHome()
        runner = try ToolRunner(
            sessionID: UUID().uuidString,
            project: home.project,
            root: ScopedRoot(home.projectURL),
            policy: ApprovalPolicy(mode: .confirm),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            gate: ApprovalGate { _ in },
        )
    }

    static let canEncodeHEIC: Bool = encoded([picture(width: 8, height: 8)], as: "public.heic") != nil

    // MARK: Pictures

    @Test
    func `a PNG comes back as text and a picture`() async throws {
        defer { home.remove() }
        try save("Assets/icon.png", Self.encoded([Self.picture(width: 100, height: 50, alpha: true)], as: "public.png"))

        let result = try await read(["path": "Assets/icon.png"])
        #expect(result.content.count == 2)
        #expect(text(result).hasPrefix("Read image Assets/icon.png: PNG, 100×50; shown as a 100×50 PNG."))
        let image = try #require(picture(result))
        #expect(image.mimeType == "image/png")
        #expect(image.width == 100 && image.height == 50)
    }

    @Test
    func `an opaque picture is sent as JPEG and a text file still reads as text`() async throws {
        defer { home.remove() }
        try save("shot.png", Self.encoded([Self.picture(width: 60, height: 40)], as: "public.png"))
        try home.write("Sources/Tweak.m", "int a = 1;\n")

        let image = try #require(try await picture(read(["path": "shot.png"])))
        #expect(image.mimeType == "image/jpeg")
        let source = try await read(["path": "Sources/Tweak.m", "frame": 2])
        #expect(source.content.count == 1)
        #expect(text(source) == "1\tint a = 1;\n2\t\n")
    }

    @Test
    func `a large photo is scaled down to fit`() async throws {
        defer { home.remove() }
        let photo = try #require(Self.encoded([Self.picture(width: 4000, height: 3000, noise: true)], as: "public.jpeg", quality: 0.9))
        #expect(photo.count > ProjectFileTools.maxReadBytes)
        try save("photo.jpg", photo)

        let result = try await read(["path": "photo.jpg"])
        #expect(text(result).hasPrefix("Read image photo.jpg: JPEG, 4000×3000; shown as a "))
        let image = try #require(picture(result))
        #expect(image.mimeType == "image/jpeg")
        #expect(max(image.width, image.height) <= FileImage.maxPixelSize)
        #expect(abs(Double(image.width) / Double(image.height) - 4.0 / 3.0) < 0.01)
        #expect(image.byteCount <= FileImage.maxBytes)
        #expect(image.byteCount <= ToolRunner.maxImageBytes)
    }

    @Test
    func `a detailed transparent picture is made smaller until it fits`() async throws {
        defer { home.remove() }
        try save("noise.png", Self.encoded([Self.picture(width: 2000, height: 2000, alpha: true, noise: true)], as: "public.png"))

        let image = try #require(try await picture(read(["path": "noise.png"])))
        #expect(image.mimeType == "image/png")
        #expect(image.width < FileImage.maxPixelSize)
        #expect(image.byteCount <= FileImage.maxBytes)
    }

    @Test
    func `an animated GIF shows the frame asked for`() async throws {
        defer { home.remove() }
        let frames = [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)].map { Self.picture(width: 16, height: 16, color: $0) }
        try save("Downloads/dragon.gif", Self.encoded(frames, as: "com.compuserve.gif"))

        let first = try await read(["path": "Downloads/dragon.gif"])
        #expect(text(first).contains("GIF, 16×16, frame 0 of 3 (frame 0 to 2 picks another)"))
        #expect(try #require(picture(first)).color == .red)
        let third = try await read(["path": "Downloads/dragon.gif", "frame": 2])
        #expect(text(third).contains("frame 2 of 3"))
        #expect(try #require(picture(third)).color == .blue)

        await #expect(throws: ToolArgumentError.self) { try await read(["path": "Downloads/dragon.gif", "frame": 3]) }
        await #expect(throws: ToolArgumentError.self) { try await read(["path": "Downloads/dragon.gif", "frame": -1]) }
    }

    @Test(.enabled(if: canEncodeHEIC))
    func `a HEIC photo is sent as JPEG`() async throws {
        defer { home.remove() }
        try save("IMG_0001.HEIC", Self.encoded([Self.picture(width: 64, height: 48, color: (0, 1, 0))], as: "public.heic"))

        let result = try await read(["path": "IMG_0001.HEIC"])
        #expect(text(result).hasPrefix("Read image IMG_0001.HEIC: HEIC, 64×48"))
        let image = try #require(picture(result))
        #expect(image.mimeType == "image/jpeg")
        #expect(image.color == .green)
    }

    @Test
    func `a photo taken sideways is shown upright`() async throws {
        defer { home.remove() }
        // Orientation 6: the stored 80×40 is seen turned a quarter, 40×80.
        try save("sideways.jpg", Self.encoded([Self.picture(width: 80, height: 40)], as: "public.jpeg", orientation: 6))

        let result = try await read(["path": "sideways.jpg"])
        #expect(text(result).hasPrefix("Read image sideways.jpg: JPEG, 40×80; shown as a 40×80 JPEG."))
        let image = try #require(picture(result))
        #expect(image.width == 40 && image.height == 80)
    }

    @Test
    func `an attachment saved without a name is read by its bytes`() async throws {
        defer { home.remove() }
        // As AgentSession saves what a message carries.
        let path = "Attachments/" + UUID().uuidString.lowercased()
        try save(path, Self.encoded([Self.picture(width: 30, height: 20)], as: "public.png"))

        let result = try await read(["path": .string(path)])
        #expect(text(result).hasPrefix("Read image \(path): PNG, 30×20"))
        #expect(picture(result) != nil)
    }

    // MARK: Refusals

    @Test
    func `another binary file is refused as before, saying what can be read`() async throws {
        defer { home.remove() }
        try save("tool", Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01] + [UInt8](repeating: 0, count: 64)))
        try home.write("big.log", String(repeating: "a", count: ProjectFileTools.maxReadBytes + 1))

        let binary = await refusal { try await read(["path": "tool"]) }
        #expect(binary.hasPrefix("tool is a binary file; file_read shows a PNG, JPEG, GIF"))
        #expect(binary.contains("for a video, extract frames as image files"))
        let large = await refusal { try await read(["path": "big.log"]) }
        #expect(large.hasPrefix("big.log is \(ProjectFileTools.maxReadBytes + 1) bytes, over the \(ProjectFileTools.maxReadBytes)-byte limit; file_read shows"))
    }

    @Test
    func `text that begins as an image does is read as text`() async throws {
        defer { home.remove() }
        try home.write("notes.txt", "GIF89a is the format of the banner\n")

        let result = try await read(["path": "notes.txt"])
        #expect(result.content.count == 1)
        #expect(text(result) == "1\tGIF89a is the format of the banner\n2\t\n")
    }

    @Test
    func `a broken image is refused as one`() async throws {
        defer { home.remove() }
        try save("broken.png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 64)))

        #expect(await refusal { try await read(["path": "broken.png"]) } == "broken.png begins as a PNG image does, but it could not be decoded")
    }

    @Test
    func `an image too large to decode is refused before decoding`() async throws {
        defer { home.remove() }
        // 72 megapixels in under 9 KB: one bit a pixel, every row zeros.
        try save("bomb.png", Self.blankPNG(width: 9000, height: 8000))
        let huge = try #require(Self.encoded([Self.picture(width: 10, height: 10)], as: "public.png"))
        try save("huge.png", huge + Data(count: ProjectFileTools.maxImageFileBytes))

        #expect(await refusal { try await read(["path": "bomb.png"]) } == "bomb.png is a 9000×8000 PNG image, over the 64-megapixel limit")
        #expect(await refusal { try await read(["path": "huge.png"]) }
            == "huge.png is a PNG image of \(huge.count + ProjectFileTools.maxImageFileBytes) bytes, over the \(ProjectFileTools.maxImageFileBytes)-byte limit")
    }

    @Test
    func `an image outside the project is not read`() throws {
        defer { home.remove() }
        let outside = home.home.appendingPathComponent("outside.png")
        try #require(Self.encoded([Self.picture(width: 10, height: 10)], as: "public.png")).write(to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: home.projectURL.appendingPathComponent("linked.png").path,
            withDestinationPath: outside.path,
        )
        let tools = try ProjectFileTools(root: ScopedRoot(home.projectURL))

        #expect(throws: PathPolicyError.outsideRoot("linked.png")) { try tools.readImage(["path": "linked.png"]) }
        #expect(throws: PathPolicyError.outsideRoot(outside.path)) { try tools.readImage(["path": .string(outside.path)]) }
        #expect(throws: PathPolicyError.outsideRoot("../../../../outside.png")) { try tools.readImage(["path": "../../../../outside.png"]) }
    }

    // MARK: - Helpers

    private func read(_ arguments: JSONValue) async throws -> AgentToolResult {
        try await runner.run(.local(.fileRead), toolCallID: "read", arguments: arguments, cancellation: nil, mcp: nil)
    }

    private func refusal(_ body: () async throws -> AgentToolResult) async -> String {
        do {
            _ = try await body()
            return "(read)"
        } catch {
            return error.localizedDescription
        }
    }

    private func save(_ relative: String, _ data: Data?) throws {
        let url = home.projectURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(data).write(to: url)
    }

    private func text(_ result: AgentToolResult) -> String {
        result.content.compactMap { block in
            if case let .text(text) = block {
                return text.text
            }
            return nil
        }.joined(separator: "\n")
    }

    /// The picture a result carries, decoded; nil without one that decodes.
    private func picture(_ result: AgentToolResult) -> Shown? {
        for case let .image(image) in result.content {
            guard let data = Data(base64Encoded: image.data),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return Shown(mimeType: image.mimeType, byteCount: data.count, image: decoded)
        }
        return nil
    }

    struct Shown {
        let mimeType: String
        let byteCount: Int
        let image: CGImage

        var width: Int {
            image.width
        }

        var height: Int {
            image.height
        }

        enum Color { case red, green, blue, other }

        /// The colour the picture is filled with.
        var color: Color {
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            switch (pixel[0] > 200, pixel[1] > 200, pixel[2] > 200) {
            case (true, false, false) where pixel[1] < 60 && pixel[2] < 60: return .red
            case (false, true, false) where pixel[0] < 60 && pixel[2] < 60: return .green
            case (false, false, true) where pixel[0] < 60 && pixel[1] < 60: return .blue
            default: return .other
            }
        }
    }

    // MARK: Fixtures

    /// A picture filled with one colour, or with noise no encoder can shrink.
    static func picture(
        width: Int,
        height: Int,
        alpha: Bool = false,
        color: (Double, Double, Double) = (1, 0, 0),
        noise: Bool = false,
    ) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue,
        )!
        if noise {
            // xorshift64: the same noise every run.
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            let words = context.data!.bindMemory(to: UInt64.self, capacity: width * height / 2)
            for index in 0 ..< width * height / 2 {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                words[index] = state
            }
        } else {
            context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: alpha ? 0.5 : 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context.makeImage()!
    }

    static func encoded(_ images: [CGImage], as type: String, quality: Double? = nil, orientation: Int? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, images.count, nil) else { return nil }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        for image in images {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A valid grey PNG, one bit a pixel and blank, written by hand: it
    /// decodes to `width`×`height` pixels from a few kilobytes.
    static func blankPNG(width: Int, height: Int) throws -> Data {
        func bigEndian(_ value: UInt32) -> [UInt8] {
            [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        }
        func crc32(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0 ..< 8 {
                    crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
                }
            }
            return ~crc
        }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            return bigEndian(UInt32(body.count)) + typed + bigEndian(crc32(typed))
        }
        // Each row is its filter byte and the row's bits, all zero.
        let rows = Data(count: (1 + (width + 7) / 8) * height)
        let deflated = try (rows as NSData).compressed(using: .zlib) as Data
        // zlib's header and Adler-32 around the raw deflate: for zero bytes
        // the checksum's low half stays 1 and its high half is the count.
        let adler = UInt32(rows.count % 65521) << 16 | 1
        let header = bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + [1, 0, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            + chunk("IHDR", header)
            + chunk("IDAT", [0x78, 0x9C] + [UInt8](deflated) + bigEndian(adler))
            + chunk("IEND", []))
    }
}
