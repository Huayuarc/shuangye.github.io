import ApelinCore
import Foundation

/// A console script: steps run in order against an `ApelinService` (the
/// app's, `ApelinService.app`, on a device). The format is written down in
/// Documents/Console.md.
public struct ConsoleScript: Decodable {
    public var name: String?
    public var steps: [ConsoleStep]

    public init(from decoder: Decoder) throws {
        // Either a bare array of steps or {"name": …, "steps": […]}.
        if let steps = try? decoder.singleValueContainer().decode([ConsoleStep].self) {
            name = nil
            self.steps = steps
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        steps = try container.decode([ConsoleStep].self, forKey: .steps)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case steps
    }
}

public struct ConsoleStep: Decodable {
    /// An `AppOperation` name, or `wait` or `expect`.
    public var op: String
    public var request: JSONValue?
    /// The name later steps use: `${label.response.taskID}`, `{"step": label}`.
    public var label: String?
    /// For an operation that answers a task: read its events until it
    /// finishes. Defaults to true.
    public var follow: Bool?
    /// Keep going when this step fails. Defaults to false.
    public var allowError: Bool?
    /// The longest a followed task is read. Defaults to 1800.
    public var timeoutSeconds: Double?
}

/// The console's own steps.
public enum ConsoleBuiltin: String, CaseIterable {
    case wait
    case expect
}

/// `expect`'s request: every field given must hold of the step it names
/// (the previous step when `step` is absent).
public struct ConsoleExpectation: Decodable {
    public var step: String?
    /// Did the step succeed?
    public var ok: Bool?
    /// The error code it failed with.
    public var errorCode: String?
    /// The final task state of a followed step.
    public var state: String?
    /// A dotted path into the step's result (`response.passed`,
    /// `events.0.kind`, `lastEvent.payload.state`) and what it must be.
    public var path: String?
    public var equals: JSONValue?
    public var exists: Bool?
}

/// What a step left behind, for `${…}` and `expect`.
struct ConsoleStepResult {
    var ok: Bool
    var response: JSONValue?
    var error: JSONValue?
    var events: [JSONValue] = []
    var state: String?

    var json: JSONValue {
        var object: [String: JSONValue] = ["ok": .bool(ok), "events": .array(events)]
        if let response {
            object["response"] = response
        }
        if let error {
            object["error"] = error
        }
        if let state {
            object["state"] = .string(state)
        }
        if let last = events.last {
            object["lastEvent"] = last
        }
        return .object(object)
    }
}

enum ConsoleSubstitution {
    /// Replaces `${label.path}` in every string of `value`. A string that is
    /// exactly one reference becomes the referenced value itself (a number
    /// stays a number); a reference inside a longer string is spliced in as text.
    static func apply(_ value: JSONValue, results: [String: ConsoleStepResult]) throws -> JSONValue {
        switch value {
        case let .string(text):
            try substitute(text, results: results)
        case let .array(items):
            try .array(items.map { try apply($0, results: results) })
        case let .object(object):
            try .object(object.mapValues { try apply($0, results: results) })
        default:
            value
        }
    }

    /// Whether any string in `value` holds a `${…}` reference.
    static func hasReference(_ value: JSONValue) -> Bool {
        switch value {
        case let .string(text): text.contains("${")
        case let .array(items): items.contains(where: hasReference)
        case let .object(object): object.values.contains(where: hasReference)
        default: false
        }
    }

    private static func substitute(_ text: String, results: [String: ConsoleStepResult]) throws -> JSONValue {
        guard text.contains("${") else { return .string(text) }
        if text.hasPrefix("${"), text.hasSuffix("}"),
           text.dropFirst(2).firstIndex(of: "}") == text.index(before: text.endIndex)
        {
            return try lookup(String(text.dropFirst(2).dropLast()), results: results)
        }
        var output = ""
        var rest = Substring(text)
        while let open = rest.range(of: "${") {
            output += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
                throw ConsoleFailure("unterminated ${ in \"\(text)\"")
            }
            let value = try lookup(String(rest[open.upperBound ..< close]), results: results)
            switch value {
            case let .string(string): output += string
            default: try output += String(decoding: JSONCoding.encode(value), as: UTF8.self)
            }
            rest = rest[rest.index(after: close)...]
        }
        return .string(output + rest)
    }

    private static func lookup(_ reference: String, results: [String: ConsoleStepResult]) throws -> JSONValue {
        let parts = reference.split(separator: ".", maxSplits: 1).map(String.init)
        guard let label = parts.first, let result = results[label] else {
            throw ConsoleFailure("no step labelled \"\(parts.first ?? "")\" before ${\(reference)}")
        }
        guard parts.count == 2 else { return result.json }
        guard let value = result.json.value(at: parts[1]) else {
            throw ConsoleFailure("${\(reference)} is not in that step's result")
        }
        return value
    }
}

struct ConsoleFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) {
        self.description = description
    }
}
