import ApelinCore
@testable import ApelinProject
import Foundation
import XCTest

/// The repository, found from this file: the fixtures and the shipped
/// extensions are read where they are.
enum Repository {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ApelinProjectTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // ApelinKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent()
    static let schemas = root.appendingPathComponent("Documents/Schemas")
    static let fixtures = schemas.appendingPathComponent("Fixtures")
    static let extensions = root.appendingPathComponent("Extensions/Development")
    static let referenceTool = schemas.appendingPathComponent("Tools")
}

func scratchDirectory(_ label: String = "apelin-i3-test") throws -> URL {
    let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("\(label).\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(fileURLWithPath: CanonicalPath.resolve(url.path)!, isDirectory: true)
}

/// Runs the reference implementation (`Documents/Schemas/Tools/apelin_schema.py`)
/// with a short script; its stdout.
func runReference(_ script: String, arguments: [String] = []) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-I", "-B", "-c", "import sys; sys.path.insert(0, sys.argv[1]); " + script, Repository.referenceTool.path] + arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let failure = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "reference", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: failure, as: UTF8.self)])
    }
    return String(decoding: data, as: UTF8.self)
}

func sampleRegistry() -> StaticEnvironmentRegistry {
    StaticEnvironmentRegistry(
        toolchains: [RegisteredToolchain(id: "clt-27.0-sample", digest: "sha256:" + String(repeating: "1", count: 64), version: "27.0", path: "/nonexistent", components: ["c-family"])],
        sdks: [RegisteredSDK(id: "iPhoneOS27.0-00000000", digest: "sha256:" + String(repeating: "2", count: 64), version: "27.0", path: "/nonexistent")],
    )
}
