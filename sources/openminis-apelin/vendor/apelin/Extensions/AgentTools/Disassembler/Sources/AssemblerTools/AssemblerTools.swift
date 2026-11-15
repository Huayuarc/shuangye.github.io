// The assembler extension links Keystone, which is GPL-2.0, and ships as
// its own package for that reason. Nothing outside apelin-assembler links
// this module.

import ApelinToolExtension
import Foundation
import Keystone

/// The assembler extension's one tool: `assemble`.
public enum AssemblerTools {
    static let id = "wiki.qaq.apelin.agent-tools.assembler"
    /// The package version. Packaging/assembler/manifest.json says the same,
    /// and a test holds the two together.
    static let version = "1.0.0"
    static let maxSourceLength = 64 * 1024

    static let assembleDescriptor = ToolDescriptor(
        name: "assemble",
        description: "Assemble instructions to machine code with Keystone. Statements are separated by newlines or semicolons. "
            + "Keystone's ARM64 predates ARMv8.3, so pointer-authentication instructions (pacibsp, retab, …) are not accepted.",
        parameters: [
            "type": "object",
            "properties": [
                "arch": [
                    "type": "string",
                    "enum": ["arm64", "x86_64", "x86", "arm", "thumb"],
                    "description": "Target architecture.",
                ],
                "source": [
                    "type": "string",
                    "minLength": 1,
                    "maxLength": .number(Double(maxSourceLength)),
                    "description": "Assembly source.",
                ],
                "address": [
                    "type": "string",
                    "description": "Address the code will run at, in hex (0x…) or decimal, for PC-relative operands. Default 0.",
                ],
                "syntax": [
                    "type": "string",
                    "enum": ["intel", "att"],
                    "description": "x86 syntax. Default intel.",
                ],
            ],
            "required": ["arch", "source"],
            "additionalProperties": false,
        ],
        risk: .readOnly,
        timeoutSeconds: 30,
    )

    public static func server() -> ToolExtensionServer {
        ToolExtensionServer(
            peer: ToolPeer(name: id, version: version),
            tools: [ToolHandler(assembleDescriptor) { call in try assemble(call) }],
        )
    }

    static func assemble(_ call: ToolCallContext) throws -> ToolOutput {
        let arch = call.arguments["arch"]?.stringValue ?? ""
        let source = call.arguments["source"]?.stringValue ?? ""
        let address = try parseAddress(call.arguments["address"]?.stringValue)
        let syntax: X86Syntax = call.arguments["syntax"]?.stringValue == "att" ? .att : .intel

        let assembler: KeystoneAssembler
        do {
            switch arch {
            case "arm64": assembler = try .arm64()
            case "x86_64": assembler = try .x86_64(syntax: syntax)
            case "x86": assembler = try .x86_32(syntax: syntax)
            case "arm": assembler = try .arm(thumb: false)
            case "thumb": assembler = try .arm(thumb: true)
            default: throw ToolFailure.invalidArguments("unknown arch \(arch)")
            }
        } catch let error as KeystoneError {
            throw ToolFailure("Keystone cannot open \(arch): \(error)")
        }
        try call.checkCancellation()

        let result: AssemblyResult
        do {
            result = try assembler.assemble(source, address: address)
        } catch let error as KeystoneError {
            throw ToolFailure("assembly failed: \(error)")
        }

        let bytes = [UInt8](result.data)
        // Keystone answers some unknown mnemonics with no code and no error.
        guard !bytes.isEmpty else {
            throw ToolFailure("Keystone produced no code from this source; check the mnemonics and syntax for \(arch)")
        }
        var lines = [
            "\(arch), \(bytes.count) bytes from \(result.statementCount) statements, at "
                + String(format: "0x%llx", address),
            "bytes: " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "),
        ]
        if ["arm64", "arm"].contains(arch), bytes.count % 4 == 0 {
            let words = stride(from: 0, to: bytes.count, by: 4).map { index -> String in
                let word = UInt32(bytes[index])
                    | UInt32(bytes[index + 1]) << 8
                    | UInt32(bytes[index + 2]) << 16
                    | UInt32(bytes[index + 3]) << 24
                return String(format: "0x%08x", word)
            }
            lines.append("words (little-endian): " + words.joined(separator: " "))
        }
        return .text(lines.joined(separator: "\n"))
    }

    static func parseAddress(_ text: String?) throws -> UInt64 {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return 0 }
        if text.lowercased().hasPrefix("0x"), let value = UInt64(text.dropFirst(2), radix: 16) {
            return value
        }
        if let value = UInt64(text) {
            return value
        }
        throw ToolFailure.invalidArguments("\(text) is not an address")
    }
}
