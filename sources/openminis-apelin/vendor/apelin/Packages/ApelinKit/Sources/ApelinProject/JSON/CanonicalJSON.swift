import CryptoKit
import Foundation

/// RFC 8785 (JCS) for the value space Apelin documents allow — no
/// non-integer numbers — and the `sha256:` digests taken over it
/// (Documents/Schemas/README.md ▸ Canonical form and digest). Byte for byte
/// the reference implementation's `canonical_json`; the fixtures in
/// `Documents/Schemas/Fixtures/canonical-json.json` hold both to it.
public enum CanonicalJSON {
    public static func data(_ value: JSONDocument) -> Data {
        var out = ""
        encode(value, into: &out)
        return Data(out.utf8)
    }

    public static func string(_ value: JSONDocument) -> String {
        var out = ""
        encode(value, into: &out)
        return out
    }

    /// `"sha256:"` + the lowercase hex SHA-256 of the canonical bytes.
    public static func digest(_ value: JSONDocument) -> String {
        sha256Tag(data(value))
    }

    public static func sha256Tag(_ data: Data) -> String {
        "sha256:" + sha256Hex(data)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encode(_ value: JSONDocument, into out: inout String) {
        switch value {
        case .null: out += "null"
        case let .bool(flag): out += flag ? "true" : "false"
        case let .integer(number): out += String(number)
        case let .string(text): out += quote(text)
        case let .array(items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 {
                    out += ","
                }
                encode(item, into: &out)
            }
            out += "]"
        case let .object(object):
            out += "{"
            let sorted = object.entries.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
            for (index, entry) in sorted.enumerated() {
                if index > 0 {
                    out += ","
                }
                out += quote(entry.key) + ":"
                encode(entry.value, into: &out)
            }
            out += "}"
        }
    }

    /// A JCS string: `"` and `\` escaped, the five short control escapes,
    /// other C0 controls as lowercase `\u00xx`, everything else as itself.
    /// The same as Python's `json.dumps(…, ensure_ascii=False)`, which the
    /// template substitution's JSON escaping is.
    public static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{8}": out += "\\b"
            case "\u{C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
