import Foundation

/// A binary package's `control` file, built field by field and written the
/// way dpkg reads it back.
///
/// Fields keep the order they were set in and the spelling they were given;
/// lookups ignore case, as dpkg's do. A value with newlines is written as a
/// folded field: each further line indented by one space, an empty line as
/// ` .` — so `Description` takes its synopsis on the first line and the
/// extended text after it.
public struct DebianControlFile: Sendable, Hashable {
    public struct Field: Sendable, Hashable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public private(set) var fields: [Field] = []

    /// The four fields every binary package needs, in dpkg's usual order.
    /// `description` is the synopsis, optionally followed by a newline and
    /// the extended description.
    public init(package: String, version: String, architecture: String, description: String) {
        self["Package"] = package
        self["Version"] = version
        self["Architecture"] = architecture
        self["Description"] = description
    }

    /// An existing control paragraph, such as a template's. Field names keep
    /// their spelling and order; a folded value is unfolded, ` .` lines back
    /// to empty ones.
    public init(parsing text: String) throws {
        let names = DebianControl.fieldNames(text)
        let multiline = Set(names.map { $0.lowercased() })
        let parsed = try DebianControl.parse(text, preservingLinesFor: multiline)
        for name in names {
            guard let value = parsed[name.lowercased()] else { continue }
            let lines = value.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
                index > 0 && line == "." ? "" : String(line)
            }
            fields.append(Field(name: name, value: lines.joined(separator: "\n")))
        }
    }

    /// The value of a field, matched without regard to case. Setting a field
    /// that exists replaces its value in place; a new one is appended; nil
    /// removes it.
    public subscript(name: String) -> String? {
        get { fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        set {
            let index = fields.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            switch (index, newValue) {
            case let (index?, value?): fields[index].value = value
            case let (index?, nil): fields.remove(at: index)
            case let (nil, value?): fields.append(Field(name: name, value: value))
            case (nil, nil): break
            }
        }
    }

    public var package: String? {
        self["Package"]
    }

    public var version: String? {
        self["Version"]
    }

    public var architecture: String? {
        self["Architecture"]
    }

    /// Checks the paragraph and returns it as dpkg reads it: one field per
    /// line, folded values, a trailing newline.
    ///
    /// Refused: a missing `Package`, `Version`, `Architecture` or
    /// `Description`; a package name outside `[a-z0-9][a-z0-9+.-]+`; a version
    /// `DebianVersion` does not accept; a field name dpkg would not read; a
    /// value with a NUL or carriage return; a single-line field that is empty.
    public func rendered() throws -> String {
        guard let package, package.utf8.count >= 2,
              package.utf8.allSatisfy({ Self.isPackageNameByte($0) }),
              let first = package.utf8.first, (0x61 ... 0x7A).contains(first) || (0x30 ... 0x39).contains(first)
        else {
            throw PackageFormatError.invalidControl("Package must match [a-z0-9][a-z0-9+.-]+")
        }
        guard let version, DebianVersion.isValid(version), version == version.trimmingCharacters(in: .whitespaces)
        else {
            throw PackageFormatError.invalidControl("Version is not a Debian version")
        }
        guard let architecture, !architecture.isEmpty, !architecture.contains(where: \.isWhitespace) else {
            throw PackageFormatError.invalidControl("Architecture is missing")
        }
        guard let description = self["Description"],
              !description.prefix(while: { $0 != "\n" }).trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw PackageFormatError.invalidControl("Description needs a synopsis")
        }

        var seen = Set<String>()
        var text = ""
        for field in fields {
            guard !field.name.isEmpty, field.name.utf8.first != UInt8(ascii: "#"),
                  field.name.utf8.first != UInt8(ascii: "-"),
                  field.name.utf8.allSatisfy({ (33 ... 126).contains($0) && $0 != 58 }),
                  seen.insert(field.name.lowercased()).inserted
            else {
                throw PackageFormatError.invalidControl("field name \(field.name.debugDescription)")
            }
            guard !field.value.utf8.contains(0), !field.value.utf8.contains(0x0D) else {
                throw PackageFormatError.invalidControl("\(field.name) holds a NUL or carriage return")
            }
            let lines = field.value.split(separator: "\n", omittingEmptySubsequences: false)
            let head = lines[0].trimmingCharacters(in: .whitespaces)
            guard lines.count > 1 || !head.isEmpty else {
                throw PackageFormatError.invalidControl("\(field.name) is empty")
            }
            text += head.isEmpty ? "\(field.name):\n" : "\(field.name): \(head)\n"
            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Kept as written after the one-space fold: a Description
                // line indented further is shown verbatim by package managers.
                text += trimmed.isEmpty ? " .\n" : " \(line)\n"
            }
        }
        return text
    }

    private static func isPackageNameByte(_ byte: UInt8) -> Bool {
        (0x61 ... 0x7A).contains(byte) || (0x30 ... 0x39).contains(byte)
            || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
    }
}
