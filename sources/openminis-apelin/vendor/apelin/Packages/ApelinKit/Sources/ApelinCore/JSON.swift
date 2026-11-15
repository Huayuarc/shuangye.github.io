import Foundation

/// One JSON configuration for everything Apelin writes: sorted keys so the
/// same value is the same bytes, ISO 8601 dates, base64 data.
public enum JSONCoding {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        return decoder
    }

    public static func encode(_ value: some Encodable) throws -> Data {
        try encoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }
}

/// Any JSON value, for payloads whose shape is not fixed (event payloads,
/// template values, UI trees) and for the console, which passes requests and
/// responses through without knowing their types.
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value):
            // Whole numbers stay integers on the wire: IDs, sequence numbers
            // and counts read back as what they were.
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// Re-encodes any Encodable as a JSONValue.
    public init(encoding value: some Encodable) throws {
        self = try JSONCoding.decode(JSONValue.self, from: JSONCoding.encode(value))
    }

    /// Decodes this value as `T`.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONCoding.decode(type, from: JSONCoding.encode(self))
    }

    /// The value at a dotted path: `response.taskID`, `events.0.kind`.
    /// Array elements are addressed by index.
    public func value(at path: String) -> JSONValue? {
        var current: JSONValue = self
        for key in path.split(separator: ".", omittingEmptySubsequences: true) {
            switch current {
            case let .object(object):
                guard let next = object[String(key)] else { return nil }
                current = next
            case let .array(array):
                guard let index = Int(key), array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(object) = self {
            return object[key]
        }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(value) = self {
            return value
        }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }
}
