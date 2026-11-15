import ApelinToolExtension
import Capstone
import Darwin
import Foundation
import MachOReader

/// The disassembler extension's tools: `disassemble` and `symbols`.
public enum DisassemblerTools {
    static let id = "wiki.qaq.apelin.agent-tools.disassembler"
    /// The package version. Packaging/disassembler/manifest.json says the
    /// same, and a test holds the two together.
    static let version = "1.1.0"
    static let maxInstructions = 1000
    static let maxSymbols = 5000
    static let maxBinaryBytes = 1 << 30
    /// The largest listing sent as a file: the host relays no attachment
    /// larger than the protocol's default.
    static let maxListingBytes = 32 << 20

    static let binaryParameter: JSONValue = [
        "type": "string",
        "minLength": 1,
        "description": "Path to a Mach-O file (thin or fat) this process can read.",
    ]
    static let archParameter: JSONValue = [
        "type": "string",
        "enum": ["arm64", "arm64e", "x86_64"],
        "description": "Slice of a fat file to read. Defaults to arm64e, then arm64, then the first slice.",
    ]

    static let disassembleDescriptor = ToolDescriptor(
        name: "disassemble",
        description: "Disassemble instructions from a Mach-O binary with Capstone, starting at a virtual address or a symbol. "
            + "Lines show address, bytes, instruction, and the symbol a branch lands on.",
        parameters: [
            "type": "object",
            "properties": [
                "binary": binaryParameter,
                "address": [
                    "type": "string",
                    "minLength": 1,
                    "description": "Start: a virtual address in hex (0x100003f50) or decimal, or a symbol name (_main or main).",
                ],
                "count": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": .number(Double(maxInstructions)),
                    "description": "Instructions to disassemble. Default 32.",
                ],
                "arch": archParameter,
            ],
            "required": ["binary", "address"],
            "additionalProperties": false,
        ],
        risk: .readOnly,
        timeoutSeconds: 30,
    )

    static let symbolsDescriptor = ToolDescriptor(
        name: "symbols",
        description: "List the symbol table (LC_SYMTAB) of a Mach-O binary, nm-style, sorted by address.",
        parameters: [
            "type": "object",
            "properties": [
                "binary": binaryParameter,
                "filter": [
                    "type": "string",
                    "description": "Only symbols whose name contains this text (case-insensitive).",
                ],
                "kind": [
                    "type": "string",
                    "enum": ["all", "defined", "undefined"],
                    "description": "Defined, undefined (imports), or all. Default all.",
                ],
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": .number(Double(maxSymbols)),
                    "description": "Symbols to return. Default 200.",
                ],
                "offset": [
                    "type": "integer",
                    "minimum": 0,
                    "description": "Matching symbols to skip, for paging. Default 0.",
                ],
                "arch": archParameter,
                "output": [
                    "type": "string",
                    "enum": ["text", "file"],
                    "description": "text: the page inline (default). file: every matching symbol, unpaged, as a text/plain attachment, with a one-line summary inline.",
                ],
            ],
            "required": ["binary"],
            "additionalProperties": false,
        ],
        risk: .readOnly,
        timeoutSeconds: 30,
    )

    public static func server() -> ToolExtensionServer {
        // A binary handed over as a descriptor is mapped, never read whole,
        // so it may be far larger than the protocol's default attachment.
        ToolExtensionServer(
            peer: ToolPeer(name: id, version: version),
            tools: [
                ToolHandler(disassembleDescriptor) { call in try disassemble(call) },
                ToolHandler(symbolsDescriptor) { call in try symbols(call) },
            ],
            limits: ToolProtocolLimits(maxAttachmentBytes: maxBinaryBytes),
        )
    }

    // MARK: - Tools

    static func disassemble(_ call: ToolCallContext) throws -> ToolOutput {
        let (image, label) = try openBinary(call)
        let slice = try image.slice(arch: call.arguments["arch"]?.stringValue)
        let index = slice.symbolIndex()
        let count = call.arguments["count"]?.intValue ?? 32
        let start = try resolveAddress(call.arguments["address"]?.stringValue ?? "", index: index)
        try call.checkCancellation()

        let disassembler: Disassembler
        let maxBytes: Int
        switch slice.cpuType {
        case MachOSlice.cpuTypeARM64:
            disassembler = try Disassembler(arch: CS_ARCH_AARCH64, mode: CS_MODE_LITTLE_ENDIAN)
            maxBytes = count * 4
        case MachOSlice.cpuTypeX86_64:
            disassembler = try Disassembler(arch: CS_ARCH_X86, mode: CS_MODE_64)
            maxBytes = count * 15
        default:
            throw ToolFailure("cannot disassemble \(slice.architecture)")
        }
        disassembler.skipData = true

        let code = try slice.bytes(atAddress: start, maxCount: maxBytes)
        let instructions = disassembler.disassemble(code: code, address: start, count: count)
        guard !instructions.isEmpty else {
            throw ToolFailure(String(format: "no instructions decoded at 0x%llx", start))
        }

        let section = slice.section(containing: start)
        var header = "\(label) (\(slice.architecture))"
        if let section {
            header += ", \(section.segment),\(section.name)"
            if !section.containsCode {
                header += " — not a code section"
            }
        }
        var lines = [header]
        if let nearest = index.nearest(start), nearest.offset != 0 {
            lines.append(String(format: "%@+0x%llx:", nearest.symbol.name, nearest.offset))
        }
        for instruction in instructions {
            if let symbol = index.symbol(at: instruction.address) {
                lines.append("\(symbol.name):")
            }
            let bytes = instruction.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            var line = String(format: "0x%llx  ", instruction.address)
                + bytes.padding(toLength: max(bytes.count, 12), withPad: " ", startingAt: 0)
            line += "  \(instruction.mnemonic)"
            if !instruction.operandString.isEmpty {
                line += " \(instruction.operandString)"
            }
            if let target = branchTarget(instruction), let name = describe(target, index: index, slice: slice) {
                line += "  ; \(name)"
            }
            lines.append(line)
        }
        if instructions.count < count {
            lines.append("(\(instructions.count) of \(count): the segment's file contents end here)")
        }
        return .text(lines.joined(separator: "\n"))
    }

    static func symbols(_ call: ToolCallContext) throws -> ToolOutput {
        let (image, label) = try openBinary(call)
        let slice = try image.slice(arch: call.arguments["arch"]?.stringValue)
        let filter = call.arguments["filter"]?.stringValue?.lowercased()
        let kind = call.arguments["kind"]?.stringValue ?? "all"
        let limit = call.arguments["limit"]?.intValue ?? 200
        let offset = call.arguments["offset"]?.intValue ?? 0

        let matching = slice.symbols.filter { symbol in
            switch kind {
            case "defined" where symbol.kind != .defined, "undefined" where !symbol.isUndefined: return false
            default: break
            }
            guard let filter, !filter.isEmpty else { return true }
            return symbol.name.lowercased().contains(filter)
        }.sorted { $0.address == $1.address ? $0.name < $1.name : $0.address < $1.address }
        try call.checkCancellation()

        let heading = "\(label) (\(slice.architecture))" + (slice.uuid.map { ", UUID \($0.uuidString)" } ?? "")
        if call.arguments["output"]?.stringValue == "file" {
            let lines = [heading, "\(matching.count) matching symbols"] + matching.map { symbolLine($0, slice: slice) }
            let name = (label as NSString).lastPathComponent + ".symbols.txt"
            let file = try listingFile(lines.joined(separator: "\n") + "\n", name: name)
            return ToolOutput([
                .text("\(matching.count) matching symbols of \(heading), in the attached \(name)"),
                .file(file),
            ])
        }

        let page = matching.dropFirst(offset).prefix(limit)
        var lines = [heading]
        if matching.isEmpty {
            lines.append("no matching symbols (\(slice.symbols.count) in the table)")
        } else {
            lines.append("\(matching.count) matching symbols; showing \(offset + 1)–\(offset + page.count)")
        }
        for symbol in page {
            lines.append(symbolLine(symbol, slice: slice))
        }
        if offset + page.count < matching.count {
            lines.append("(\(matching.count - offset - page.count) more; pass offset \(offset + page.count))")
        }
        return .text(lines.joined(separator: "\n"))
    }

    /// nm's line: address, type letter, name.
    static func symbolLine(_ symbol: MachOSymbol, slice: MachOSlice) -> String {
        let letter = typeLetter(symbol, slice: slice)
        let address = symbol.isUndefined
            ? String(repeating: " ", count: 18) : String(format: "0x%016llx", symbol.address)
        return "\(address) \(letter) \(symbol.name)"
    }

    /// `text` in a temporary file unlinked as soon as it is made, so the
    /// descriptor sent is the only way to it.
    static func listingFile(_ text: String, name: String) throws -> ToolOutgoingAttachment {
        let data = Data(text.utf8)
        guard data.count <= maxListingBytes else {
            throw ToolFailure("the listing is \(data.count) bytes, over \(maxListingBytes); narrow it with filter or kind")
        }
        for directory in [NSTemporaryDirectory(), "/var/tmp", "/tmp"] {
            let prefix = directory.hasSuffix("/") ? directory : directory + "/"
            var template = Array((prefix + "apelin-disassembler.XXXXXX").utf8CString)
            let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
            guard descriptor >= 0 else { continue }
            unlink(String(cString: template))
            defer { close(descriptor) }
            var written = 0
            try data.withUnsafeBytes { raw in
                while written < raw.count {
                    let count = write(descriptor, raw.baseAddress! + written, raw.count - written)
                    if count < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw ToolFailure("the listing cannot be written: \(String(cString: strerror(errno)))")
                    }
                    written += count
                }
            }
            return try ToolOutgoingAttachment(duplicating: descriptor, mimeType: "text/plain", name: name)
        }
        throw ToolFailure("no temporary file can be made for the listing")
    }

    // MARK: - Helpers

    /// The binary named by `binary`: the descriptor the host passed for it,
    /// or the path, opened by this process.
    static func openBinary(_ call: ToolCallContext) throws -> (MachOFile, String) {
        let path = call.arguments["binary"]?.stringValue ?? ""
        do {
            if let attachment = try call.attachment(forArgument: "binary") {
                return try (MachOFile(MappedFile(descriptor: attachment.descriptor)), attachment.name ?? path)
            }
            return try (MachOFile(MappedFile(path: path)), path)
        } catch let error as MachOError {
            throw ToolFailure("\(path): \(error)")
        }
    }

    static func resolveAddress(_ text: String, index: MachOSymbolIndex) throws -> UInt64 {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x"), let value = UInt64(trimmed.dropFirst(2), radix: 16) {
            return value
        }
        if let value = UInt64(trimmed) {
            return value
        }
        if let symbol = index.symbol(named: trimmed) {
            return symbol.address
        }
        throw ToolFailure.invalidArguments("\(text) is neither an address nor a defined symbol")
    }

    /// The immediate a direct branch or address computation names.
    static func branchTarget(_ instruction: Instruction) -> UInt64? {
        let mnemonic = instruction.mnemonic.lowercased()
        // Not adrp: its operand is a page, and the symbol nearest a page
        // boundary says nothing about what the pair addresses.
        let branches = ["b", "bl", "cbz", "cbnz", "tbz", "tbnz", "adr", "call"]
        guard branches.contains(mnemonic) || mnemonic.hasPrefix("b.") || (mnemonic.hasPrefix("j") && mnemonic.count <= 4), let range = instruction.operandString.range(of: "0x", options: .backwards) else { return nil }
        let digits = instruction.operandString[range.upperBound...].prefix { $0.isHexDigit }
        return UInt64(digits, radix: 16)
    }

    static func describe(_ address: UInt64, index: MachOSymbolIndex, slice: MachOSlice) -> String? {
        if let symbol = index.symbol(at: address) {
            return symbol.name
        }
        guard let nearest = index.nearest(address), let section = slice.section(containing: address),
              slice.section(containing: nearest.symbol.address) == section
        else { return nil }
        return String(format: "%@+0x%llx", nearest.symbol.name, nearest.offset)
    }

    /// nm's letter: T text, D data, B bss, S other section, U undefined,
    /// A absolute, I indirect; lowercase when local.
    static func typeLetter(_ symbol: MachOSymbol, slice: MachOSlice) -> String {
        let letter: String
        switch symbol.kind {
        case .undefined, .preboundUndefined: return "U"
        case .absolute: letter = "A"
        case .indirect: letter = "I"
        case .defined:
            let ordinal = Int(symbol.section)
            if ordinal >= 1, ordinal <= slice.sections.count {
                let section = slice.sections[ordinal - 1]
                switch (section.segment, section.name) {
                case ("__TEXT", "__text"): letter = "T"
                case (_, "__bss"), (_, "__common"): letter = "B"
                case ("__DATA", "__data"), ("__DATA_CONST", _), ("__DATA_DIRTY", _): letter = "D"
                default: letter = "S"
                }
            } else {
                letter = "S"
            }
        }
        return symbol.isExternal ? letter : letter.lowercased()
    }
}
