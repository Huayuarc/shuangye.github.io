import Foundation

/// The part of JSON Schema a tool's parameters use: `type` (one name or a
/// list), `properties`, `required`, `additionalProperties: false`, `enum`,
/// `items`, `minimum`/`maximum`, `minLength`/`maxLength`, `maxItems`.
/// Anything else in a schema is description and passes. Both ends check
/// arguments with it: the host before a call leaves, the extension before a
/// handler sees them.
public enum ToolSchemaValidator {
    /// The first problem found, or nil.
    public static func problem(with value: JSONValue, against schema: JSONValue, at path: String = "args") -> String? {
        guard case let .object(rules) = schema else { return nil }

        if let type = rules["type"] {
            let names: [String] = switch type {
            case let .string(name): [name]
            case let .array(list): list.compactMap(\.stringValue)
            default: []
            }
            if !names.isEmpty, !names.contains(where: { matches(value, type: $0) }) {
                return "\(path) must be \(names.joined(separator: " or "))"
            }
        }

        if let options = rules["enum"]?.arrayValue, !options.contains(value) {
            let listed = options.compactMap { $0.stringValue ?? $0.intValue.map(String.init) }
            return "\(path) must be one of \(listed.joined(separator: ", "))"
        }

        switch value {
        case let .object(object):
            let properties = rules["properties"]?.objectValue ?? [:]
            for name in rules["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[name] == nil {
                return "\(path).\(name) is required"
            }
            if rules["additionalProperties"] == .bool(false), let extra = object.keys.sorted().first(where: { properties[$0] == nil }) {
                return "\(path).\(extra) is not a parameter"
            }
            for (name, member) in object.sorted(by: { $0.key < $1.key }) {
                if let rule = properties[name], let problem = problem(with: member, against: rule, at: "\(path).\(name)") {
                    return problem
                }
            }
        case let .array(items):
            if let limit = rules["maxItems"]?.intValue, items.count > limit {
                return "\(path) has more than \(limit) items"
            }
            if let rule = rules["items"] {
                for (index, item) in items.enumerated() {
                    if let problem = problem(with: item, against: rule, at: "\(path)[\(index)]") {
                        return problem
                    }
                }
            }
        case let .number(number):
            if let minimum = rules["minimum"]?.doubleValue, number < minimum {
                return "\(path) must be at least \(format(minimum))"
            }
            if let maximum = rules["maximum"]?.doubleValue, number > maximum {
                return "\(path) must be at most \(format(maximum))"
            }
        case let .string(string):
            if let minimum = rules["minLength"]?.intValue, string.count < minimum {
                return "\(path) is shorter than \(minimum) characters"
            }
            if let maximum = rules["maxLength"]?.intValue, string.count > maximum {
                return "\(path) is longer than \(maximum) characters"
            }
        default:
            break
        }
        return nil
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("number", .number), ("string", .string),
             ("array", .array), ("object", .object):
            true
        case let ("integer", .number(number)):
            number.rounded() == number
        default:
            false
        }
    }

    private static func format(_ number: Double) -> String {
        Int64(exactly: number).map { String($0) } ?? String(number)
    }
}
