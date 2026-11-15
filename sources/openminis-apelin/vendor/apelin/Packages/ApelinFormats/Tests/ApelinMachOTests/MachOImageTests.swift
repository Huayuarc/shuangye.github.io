@testable import ApelinMachO
import Foundation
import Testing

/// The fixtures are built by `Fixtures/build.sh` and committed; the UUIDs
/// below are what that build produced and change only when it is rerun.
struct MachOImageTests {
    static func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "binaries/\(name)", withExtension: nil))
        return url.path
    }

    @Test func `thin signed dylib`() throws {
        let image = try MachOImage(contentsOfFile: Self.fixture("ios-arm64.dylib"))
        #expect(!image.isUniversal)
        let slice = try #require(image.slices.first)
        #expect(image.slices.count == 1)
        #expect(slice.architecture == "arm64")
        #expect(slice.fileType == .dynamicLibrary)
        #expect(slice.isSixtyFourBit)
        #expect(!slice.isBigEndian)
        #expect(slice.offset == 0)
        #expect(slice.uuid == UUID(uuidString: "7ED9C56B-2EC0-3990-AAF7-B8801C595574"))
        #expect(slice.installName == "@rpath/ApelinFixture.dylib")
        #expect(slice.linkedLibraries == [
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
            "/usr/lib/libSystem.B.dylib",
        ])
        #expect(slice.isCodeSigned)
        #expect(!slice.isEncrypted)

        let entitlements = try #require(try image.entitlementsDictionary(of: slice))
        #expect(entitlements["wiki.qaq.apelin.fixture"] as? Bool == true)

        let inspection = try image.inspect(slice)
        #expect(inspection.platform == .iOS)
        #expect(inspection.platform?.name == "iOS")
        #expect(inspection.minimumOS == "16.0.0")
        #expect(inspection.runpaths == ["@loader_path/Frameworks"])
        #expect(inspection.segments.map(\.name) == ["__TEXT", "__DATA_CONST", "__LINKEDIT"])
        let text = try #require(inspection.segments.first)
        #expect(text.sections.contains("__text"))
        #expect(text.protections == "r-x")
        #expect(text.fileOffset == 0)
        #expect(inspection.flags.contains("TWOLEVEL"))
        #expect(inspection.flags.contains("DYLDLINK"))
        #expect(inspection.loadCommands.map(\.name).contains("LC_ID_DYLIB"))
        #expect(inspection.loadCommands.map(\.name).contains("LC_LOAD_WEAK_DYLIB"))
        #expect(inspection.loadCommands.allSatisfy { !$0.name.hasPrefix("0x") })
        #expect(inspection.signingIdentifier == "wiki.qaq.apelin.fixture")
        #expect(inspection.isAdHoc == true)
        #expect(inspection.teamIdentifier == nil)
        #expect(inspection.entryOffset == nil)
        #expect(inspection.symbolCount != nil)
        #expect(inspection.encryptionMethod == 0)
    }

    @Test func `fat executable`() throws {
        let image = try MachOImage(contentsOfFile: Self.fixture("macos-fat"))
        #expect(image.isUniversal)
        #expect(image.slices.map(\.architecture) == ["x86_64", "arm64"])
        #expect(image.slices.map(\.uuid) == [
            UUID(uuidString: "0CC81FA2-7A61-347B-AA43-6F7C2EA2722F"),
            UUID(uuidString: "51905831-E7CA-3458-8C26-609F70FB2DDA"),
        ])
        for slice in image.slices {
            #expect(slice.fileType == .executable)
            #expect(slice.offset > 0)
            #expect(slice.isCodeSigned)
            #expect(slice.headerFlags & 0x200000 != 0) // MH_PIE
            let inspection = try image.inspect(slice)
            #expect(inspection.platform == .macOS)
            #expect(inspection.minimumOS == "13.0.0")
            #expect(inspection.entryOffset != nil)
            #expect(inspection.segments.first?.name == "__PAGEZERO")
            #expect(inspection.segments.first?.protections == "---")
            #expect(inspection.isAdHoc == true)
            #expect(try image.entitlements(of: slice) == nil)
        }
    }

    @Test func `unsigned arm 64 e`() throws {
        let image = try MachOImage(contentsOfFile: Self.fixture("ios-arm64e-unsigned"))
        let slice = try #require(image.slices.first)
        #expect(slice.architecture == "arm64e")
        #expect(slice.uuid == UUID(uuidString: "7E06CB6F-558F-3F05-A49A-CFE6B4BCA99B"))
        #expect(!slice.isCodeSigned)
        #expect(try image.entitlements(of: slice) == nil)
        let inspection = try image.inspect(slice)
        #expect(inspection.flags.contains("PIE"))
        #expect(inspection.signingIdentifier == nil)
        #expect(inspection.platform == .iOS)
        #expect(inspection.dyldInfo == nil, "chained fixups")
    }

    /// The same flat lookup through two linkers: CLT 15.3's threaded binds
    /// keep each slot's signature, CLT 15.0's plain opcodes bind them unsigned.
    @Test func `arm 64 e binds that keep or drop pointer signatures`() throws {
        let threaded = try MachOImage(contentsOfFile: Self.fixture("ios-arm64e-threaded-binds"))
        let threadedSlice = try #require(threaded.slices.first)
        let kept = try #require(try threaded.inspect(threadedSlice).dyldInfo)
        #expect(kept.bindsAreThreaded)
        #expect(kept.rebaseByteCount == 0)
        #expect(!kept.dropsPointerSignatures)

        let plain = try MachOImage(contentsOfFile: Self.fixture("ios-arm64e-plain-binds"))
        let slice = try #require(plain.slices.first)
        #expect(slice.architecture == "arm64e")
        let dropped = try #require(try plain.inspect(slice).dyldInfo)
        #expect(!dropped.bindsAreThreaded)
        #expect(dropped.rebaseByteCount > 0)
        #expect(dropped.bindByteCount > 0)
        #expect(dropped.dropsPointerSignatures)
    }

    @Test func `every source reads the same`() throws {
        let path = try Self.fixture("macos-fat")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let descriptor = open(path, O_RDONLY)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        let fromDescriptor = try MachOImage(descriptor: descriptor)
        let fromData = try MachOImage(data: data)
        #expect(fromDescriptor.slices == fromData.slices)
        #expect(try fromDescriptor.inspect(fromDescriptor.slices[1]) == fromData.inspect(fromData.slices[1]))
    }

    @Test func `data with non zero start index`() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.fixture("ios-arm64.dylib")))
        let padded = Data([0xAA, 0xBB]) + data
        let sliced = padded[padded.startIndex + 2 ..< padded.endIndex]
        #expect(sliced.startIndex == 2)
        let image = try MachOImage(data: sliced)
        let slice = try #require(image.slices.first)
        #expect(slice.installName == "@rpath/ApelinFixture.dylib")
        #expect(try image.inspect(slice).runpaths == ["@loader_path/Frameworks"])
        #expect(try image.entitlements(of: slice) != nil)
    }

    @Test func `architecture names`() {
        #expect(architectureName(cpuType: 0x0100_000C, cpuSubtype: 2) == "arm64e")
        #expect(architectureName(cpuType: 0x0100_000C, cpuSubtype: Int32(bitPattern: 0x8000_0002)) == "arm64e")
        #expect(architectureName(cpuType: 0x0100_0007, cpuSubtype: 3) == "x86_64")
        #expect(architectureName(cpuType: 99, cpuSubtype: 1) == "cputype 99 subtype 1")
    }
}

/// Hostile and broken input: every case throws, none traps.
struct MachOImageDamageTests {
    @Test func `not mach O`() {
        #expect(throws: FormatFailure.notRecognised) { try MachOImage(data: Data("#!/bin/sh\nexit 0\n".utf8)) }
        #expect(throws: FormatFailure.notRecognised) { try MachOImage(data: Data()) }
    }

    @Test func `truncated header`() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: MachOImageTests.fixture("ios-arm64.dylib")))
        #expect(throws: FormatFailure.self) { try MachOImage(data: data.prefix(100)) }
        #expect(throws: FormatFailure.self) { try MachOImage(data: data.prefix(20)) }
    }

    @Test func `fat count out of range`() {
        var data = Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x03, 0xE8])
        data.append(Data(count: 64))
        #expect(throws: FormatFailure.damaged("its list of architectures could not be read")) {
            try MachOImage(data: data)
        }
    }

    @Test func `fat slice outside file`() {
        var data = Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 1])
        // cputype, subtype, offset 0x1000, size 0x1000, align
        data.append(contentsOf: [0x01, 0, 0, 0x0C, 0, 0, 0, 0, 0, 0, 0x10, 0, 0, 0, 0x10, 0, 0, 0, 0, 14])
        #expect(throws: FormatFailure.self) { try MachOImage(data: data) }
    }

    @Test func `load commands larger than file`() throws {
        var data = try Data(contentsOf: URL(fileURLWithPath: MachOImageTests.fixture("ios-arm64.dylib")))
        data.replaceSubrange(20 ..< 24, with: [0xFF, 0xFF, 0xFF, 0x7F]) // sizeofcmds
        #expect(throws: FormatFailure.self) { try MachOImage(data: data) }
    }

    @Test func `zero sized load command`() throws {
        var data = try Data(contentsOf: URL(fileURLWithPath: MachOImageTests.fixture("ios-arm64.dylib")))
        data.replaceSubrange(36 ..< 40, with: [0, 0, 0, 0]) // first command's cmdsize
        #expect(throws: FormatFailure.damaged("part of its header is the wrong size")) { try MachOImage(data: data) }
    }

    @Test func `dylib name offset outside command`() throws {
        let path = try MachOImageTests.fixture("ios-arm64.dylib")
        var data = try Data(contentsOf: URL(fileURLWithPath: path))
        let image = try MachOImage(data: data)
        let inspection = try image.inspect(image.slices[0])
        // Point LC_ID_DYLIB's name offset past the end of the command.
        var offset = 32
        for command in inspection.loadCommands {
            if command.name == "LC_ID_DYLIB" {
                break
            }
            offset += Int(command.byteCount)
        }
        data.replaceSubrange(offset + 8 ..< offset + 12, with: [0xFF, 0, 0, 0])
        let damaged = try MachOImage(data: data)
        #expect(damaged.slices[0].installName == nil)
    }

    /// Thousands of single-byte corruptions of the header and command region.
    /// Each parse either succeeds or throws; any trap fails the whole run.
    @Test func `corrupted bytes never trap`() throws {
        let original = try Data(contentsOf: URL(fileURLWithPath: MachOImageTests.fixture("ios-arm64.dylib")))
        let image = try MachOImage(data: original)
        let signature = try #require(image.slices[0].signature)
        var generator = SplitMix64(seed: 0xA9E1_1D00)
        let regions = [0 ..< 1200, Int(signature.offset) ..< Int(signature.offset) + 256]
        for iteration in 0 ..< 4000 {
            var data = original
            let region = regions[iteration % regions.count]
            for _ in 0 ..< 1 + Int(generator.next() % 3) {
                let position = region.lowerBound + Int(generator.next() % UInt64(region.count))
                data[position] = UInt8(truncatingIfNeeded: generator.next())
            }
            guard let damaged = try? MachOImage(data: data) else { continue }
            for slice in damaged.slices {
                _ = try? damaged.inspect(slice)
                _ = try? damaged.entitlements(of: slice)
            }
        }
    }
}

/// A seeded generator so a failing input can be reproduced.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
