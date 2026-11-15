import enum ApelinProtocol.AgentToolName
import ApelinToolCore
import Foundation
import KWWKAI

// ApelinToolCore has a JSONValue and a ToolDescriptor of its own: this file
// spells each with its module.

/// An installed agent tool extension (Milestone 1 §6) whose tools a session
/// offers: a package of its own, whose manifest the session host validates
/// again and whose executable it starts as mobile when one of them is called.
struct OfferedToolExtension: Sendable, Hashable {
    var id: String
    var name: String
    var version: String
    /// The tools offered, in the manifest's order: those its rules leave
    /// out are not here.
    var tools: [ApelinToolCore.ToolDescriptor]

    /// The sentence each of its tools' descriptions ends with. It inherits
    /// the session host's working directory, never the project's.
    var origin: String {
        "From \(name) \(version), an agent tool extension: it runs in its own process as mobile, outside the project, so give it absolute paths."
    }
}

/// One tool of an offered extension, as the approval gate and the runner
/// know it. Its `risk` is the extension's claim and decides nothing.
public struct ExtensionTool: Sendable, Hashable {
    /// The manifest's name, which the model calls.
    public var name: String
    public var extensionID: String
    public var extensionName: String
    public var extensionVersion: String
    /// The manifest's bound, which the host caps.
    public var timeoutSeconds: Double?
    /// The arguments its schema requires, which an empty value never drops.
    var required: Set<String>
}

/// What a session offers of the installed agent tool extensions, read from
/// `<install root>/usr/share/apelin/agent-tools/` as the host reads it.
///
/// A tool keeps its manifest's name when that name is one every provider
/// takes (`AgentToolName`'s rule), is no built-in's, today's or an earlier
/// release's, takes no argument named `reason`, which every call carries for
/// the user, and is declared by one extension only: otherwise it is left
/// out, both of a duplicate. A manifest that does not validate is left out
/// alone. Extensions in id order, tools in manifest order: the tool list is
/// the start of the provider's cached prefix.
struct ToolExtensionOffer: Sendable, Equatable {
    var extensions: [OfferedToolExtension] = []
    /// Why each extension or tool is not offered, one line each, for the log.
    var leftOut: [String] = []

    static let none = ToolExtensionOffer()

    /// Nothing is offered where there is no install root (the Mac tests).
    static func read(installRoot: String?, policy: ToolManifestPolicy) -> ToolExtensionOffer {
        guard let installRoot else { return .none }
        return offer(ToolManifestValidator.discover(installRoot: installRoot, policy: policy))
    }

    static func offer(_ discovered: [Result<ValidatedToolManifest, ToolManifestError>]) -> ToolExtensionOffer {
        var leftOut: [String] = []
        var manifests: [ValidatedToolManifest] = []
        for result in discovered {
            switch result {
            case let .success(validated): manifests.append(validated)
            case let .failure(error): leftOut.append("\(error.id): \(error.reason)")
            }
        }
        manifests.sort { $0.manifest.id < $1.manifest.id }

        func refusal(_ tool: ApelinToolCore.ToolDescriptor) -> String? {
            if !isProviderSafe(tool.name) {
                return "is not a name every model provider takes: lowercase letters, digits and single underscores, a letter first, at most 64"
            }
            if AgentToolName.canonical(tool.name) != nil {
                return "is the name of one of Apelin's own tools"
            }
            if tool.parameters["properties"]?[ToolReason.key] != nil {
                return "takes an argument named \(ToolReason.key), which every call carries for the user"
            }
            return nil
        }
        var declaring: [String: [String]] = [:]
        for validated in manifests {
            for tool in validated.manifest.tools where refusal(tool) == nil {
                declaring[tool.name, default: []].append(validated.manifest.id)
            }
        }
        var extensions: [OfferedToolExtension] = []
        for validated in manifests {
            let manifest = validated.manifest
            var tools: [ApelinToolCore.ToolDescriptor] = []
            for tool in manifest.tools {
                if let refusal = refusal(tool) {
                    leftOut.append("\(manifest.id): tool \(tool.name) \(refusal)")
                } else if let others = declaring[tool.name]?.filter({ $0 != manifest.id }), !others.isEmpty {
                    leftOut.append("\(manifest.id): tool \(tool.name) is declared by \(others.joined(separator: " and ")) as well")
                } else {
                    tools.append(tool)
                }
            }
            guard !tools.isEmpty else { continue }
            extensions.append(OfferedToolExtension(id: manifest.id, name: manifest.name, version: manifest.version, tools: tools))
        }
        return ToolExtensionOffer(extensions: extensions, leftOut: leftOut)
    }

    /// `AgentToolNameTests`' rule for Apelin's own tools: `[a-z0-9_]`, a
    /// letter first, no `__` (kwwk's MCP spelling) and no `_` at the end,
    /// at most 64.
    static func isProviderSafe(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        let letter = { (byte: UInt8) -> Bool in byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z") }
        let digit = { (byte: UInt8) -> Bool in byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
        let underscore = UInt8(ascii: "_")
        guard (1 ... 64).contains(bytes.count), letter(bytes[0]), bytes.last != underscore else { return false }
        return zip(bytes, bytes.dropFirst()).allSatisfy { previous, byte in
            letter(byte) || digit(byte) || (byte == underscore && previous != underscore)
        }
    }

    var tools: [ExtensionTool] {
        extensions.flatMap { $0.definitions.map(\.tool) }
    }

    /// Whether `name` is one of the tools offered.
    func offers(_ name: String) -> Bool {
        extensions.contains { $0.tools.contains { $0.name == name } }
    }

    /// `# Environment`'s lines for the extensions offered, none when none
    /// is: one installed or removed while a session runs reaches the model
    /// as the lines that came and went, and its tools with them.
    static func environmentLines(_ extensions: [OfferedToolExtension]) -> [String] {
        guard !extensions.isEmpty else { return [] }
        let header = "- Agent tool extensions, packages the user installs and removes with their package manager, whose tools are among yours. Each runs in its own process as mobile, outside the project, so give it absolute paths; their tools ask in Strict mode:"
        return [header] + extensions.map { offered in
            "  - \(offered.name) \(offered.version) (\(offered.id)): \(offered.tools.map(\.name).joined(separator: ", "))."
        }
    }

    /// Writes what is left out to the device log.
    func logLeftOut() {
        for line in leftOut {
            NSLog("apelin-agent: agent tool extension not offered: %@", line)
        }
    }
}

extension OfferedToolExtension {
    /// Each tool as the gate and the runner know it, with its definition
    /// for the model: the manifest's description and schema, the sentence
    /// naming the extension, and the `reason` every tool asks for.
    var definitions: [(tool: ExtensionTool, description: String, parameters: KWWKAI.JSONValue)] {
        tools.map { tool in
            var schema = Self.value(tool.parameters)
            if case var .object(fields) = schema, fields["properties"] == nil {
                // ToolReason adds its argument to the properties there are.
                fields["properties"] = .object([:])
                schema = .object(fields)
            }
            let callable = ExtensionTool(
                name: tool.name,
                extensionID: id,
                extensionName: name,
                extensionVersion: version,
                timeoutSeconds: tool.timeoutSeconds,
                required: Set(tool.parameters["required"]?.arrayValue?.compactMap(\.stringValue) ?? []),
            )
            return (callable, "\(tool.description)\n\n\(origin)", ToolReason.adding(to: schema))
        }
    }

    /// ApelinToolCore's JSON as kwwk's: a whole number is an integer, as a
    /// schema's `minimum` or `maxLength` is.
    static func value(_ json: ApelinToolCore.JSONValue) -> KWWKAI.JSONValue {
        switch json {
        case .null: .null
        case let .bool(flag): .bool(flag)
        case let .number(number):
            if let integer = Int(exactly: number) {
                .int(integer)
            } else {
                .double(number)
            }
        case let .string(text): .string(text)
        case let .array(items): .array(items.map(value))
        case let .object(fields): .object(fields.mapValues(value))
        }
    }
}
