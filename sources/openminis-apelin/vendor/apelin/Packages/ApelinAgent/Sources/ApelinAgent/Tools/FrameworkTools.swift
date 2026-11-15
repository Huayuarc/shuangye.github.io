import Foundation
import KWWKAI

/// `apelin_sdk_analyze_framework` and `apelin_sdk_read_header`: read a registered SDK's
/// `.tbd` stubs and headers directly, as mobile. The SDK root comes from the
/// host; every read stays inside it.
///
/// A framework is looked up in `Frameworks` and `PrivateFrameworks` both
/// (`private` only says which comes first), and a header named after a class
/// it does not have is answered with the header that declares the class:
/// models guessed the folder and the header's name, and stopped at "does
/// not exist".
struct FrameworkTools: Sendable {
    let sdk: ScopedRoot

    static let maxHeaderBytes = 2 * 1024 * 1024
    static let maxScannedHeaders = 2000
    static let maxSimilarFrameworks = 20
    static let maxListedDeclarations = 40

    func analyze(_ arguments: JSONValue) throws -> String {
        let name = try frameworkName(arguments)
        let filter = arguments.argString("symbol_filter")
        let framework = try locate(name, privateFirst: arguments.argBool("private"))
        let tbdPath = try sdk.resolveExisting("\(framework.path)/\(name).tbd")
        let text = try readSDKText(tbdPath, limit: 32 * 1024 * 1024)
        let stub = TBDStub.parse(text)

        var lines = [framework.title]
        if let installName = stub.installName {
            lines.append("install name: \(installName)")
        }
        if !stub.targets.isEmpty {
            lines.append("targets: \(stub.targets.joined(separator: ", "))")
        }
        if let version = stub.currentVersion {
            lines.append("current version: \(version)")
        }
        if !stub.reexports.isEmpty {
            lines.append("re-exports: \(stub.reexports.joined(separator: ", "))")
        }

        let symbols = stub.symbols.filter { filter == nil || $0.localizedCaseInsensitiveContains(filter!) }
        let classes = stub.objcClasses.filter { filter == nil || $0.localizedCaseInsensitiveContains(filter!) }
        lines.append(
            "exported symbols: \(stub.symbols.count)\(filter.map { ", \(symbols.count) matching '\($0)'" } ?? "")",
        )
        lines.append(contentsOf: symbols.prefix(300).map { "  \($0)" })
        if symbols.count > 300 {
            lines.append("  … \(symbols.count - 300) more; narrow with symbol_filter")
        }
        lines.append(
            "Objective-C classes: \(stub.objcClasses.count)\(filter.map { ", \(classes.count) matching '\($0)'" } ?? "")",
        )
        lines.append(contentsOf: classes.prefix(300).map { "  \($0)" })
        if classes.count > 300 {
            lines.append("  … \(classes.count - 300) more")
        }

        let headers = headerNames(framework.path)
        lines.append("headers: \(headers.count)")
        lines.append(contentsOf: headers.prefix(200).map { "  \($0)" })
        return lines.joined(separator: "\n")
    }

    func header(_ arguments: JSONValue) throws -> String {
        let name = try frameworkName(arguments)
        let header = arguments.argString("header")
        let symbol = arguments.argString("symbol")
        guard header == nil || symbol == nil else {
            throw ToolArgumentError("pass header or symbol, not both")
        }
        if let symbol, !Self.isIdentifier(symbol) {
            throw ToolArgumentError("symbol must be a C or Objective-C name, like VNFaceObservation")
        }
        let framework = try locate(name, privateFirst: arguments.argBool("private"))
        if let symbol {
            return framework.title + "\n" + declaringHeaders(symbol, in: framework)
        }
        guard let header else {
            let headers = headerNames(framework.path)
            return framework.title + "\n" + (headers.isEmpty ? noHeaders(framework) : headers.joined(separator: "\n"))
        }
        guard !header.contains("/"), !header.contains("\0"), !header.hasPrefix(".") else {
            throw ToolArgumentError("header must be a file name")
        }
        do {
            let path = try sdk.resolveExisting("\(framework.path)/Headers/\(header)")
            return try framework.title + "\n" + readSDKText(path, limit: Self.maxHeaderBytes)
        } catch PathPolicyError.notFound {
            return framework.title + "\n" + missingHeader(header, in: framework)
        }
    }

    // MARK: - Finding the framework

    /// Where a framework was found.
    struct Location {
        let name: String
        /// Relative to the SDK root, as its realpath names it.
        let path: String
        let isPrivate: Bool
        /// The folder `private` named, when the framework was not there.
        let missedFolder: String?

        /// `SpringBoardHome.framework (PrivateFrameworks)`, and the folder
        /// asked for when it was the other one.
        var title: String {
            let missed = missedFolder.map { "; not in \($0)" } ?? ""
            return "\(name).framework (\(FrameworkTools.folder(isPrivate))\(missed))"
        }
    }

    static func folder(_ isPrivate: Bool) -> String {
        isPrivate ? "PrivateFrameworks" : "Frameworks"
    }

    /// `Frameworks`, then `PrivateFrameworks`; `private: true` turns the
    /// order round. A link out of the SDK is refused, not passed over.
    private func locate(_ name: String, privateFirst: Bool?) throws -> Location {
        for isPrivate in privateFirst == true ? [true, false] : [false, true] {
            do {
                let real = try sdk.resolveExisting("System/Library/\(Self.folder(isPrivate))/\(name).framework")
                let missed = privateFirst.flatMap { $0 == isPrivate ? nil : Self.folder($0) }
                return Location(name: name, path: sdk.relative(real), isPrivate: isPrivate, missedFolder: missed)
            } catch PathPolicyError.notFound {
                continue
            }
        }
        let similar = similarFrameworks(name)
        var message = "No framework named \(name) in Frameworks or PrivateFrameworks of this SDK; "
        message += similar.isEmpty
            ? "none there has a similar name"
            : "similar: \(similar.joined(separator: ", "))"
        if (try? sdk.resolveExisting("System/Library/PrivateFrameworks")) == nil {
            message += ". This SDK has no PrivateFrameworks folder"
        }
        throw ToolArgumentError(message)
    }

    /// The frameworks of both folders whose name contains `name`, or is
    /// contained in it, ignoring case: a same-name match first.
    private func similarFrameworks(_ name: String) -> [String] {
        var names: Set<String> = []
        for isPrivate in [false, true] {
            guard let folder = try? sdk.resolveExisting("System/Library/\(Self.folder(isPrivate))"),
                  let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for entry in entries where entry.hasSuffix(".framework") {
                let candidate = String(entry.dropLast(".framework".count))
                if candidate.localizedCaseInsensitiveContains(name)
                    || (candidate.count >= 3 && name.localizedCaseInsensitiveContains(candidate))
                {
                    names.insert(candidate)
                }
            }
        }
        let sameName = names.filter { $0.caseInsensitiveCompare(name) == .orderedSame }
        let rest = names.subtracting(sameName).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return Array((sameName.sorted() + rest).prefix(Self.maxSimilarFrameworks))
    }

    // MARK: - Finding the header

    /// A header name the framework does not have: the header that declares
    /// the name it was given (`VNFaceObservation.h` for a class declared in
    /// `VNObservation.h`), else the headers there are.
    private func missingHeader(_ header: String, in framework: Location) -> String {
        let headers = headerNames(framework.path)
        guard !headers.isEmpty else { return noHeaders(framework) }
        let stem = header.hasSuffix(".h") ? String(header.dropLast(2)) : header
        let notHere = "\(header) is not a header of \(framework.name).framework"
        if Self.isIdentifier(stem), let found = declarations(of: stem, in: framework, headers: headers) {
            return "\(notHere); \(found)"
        }
        return "\(notHere); its headers are:\n" + headers.joined(separator: "\n")
    }

    /// The headers that declare `symbol`, or why none was found.
    private func declaringHeaders(_ symbol: String, in framework: Location) -> String {
        let headers = headerNames(framework.path)
        guard !headers.isEmpty else { return noHeaders(framework) }
        return declarations(of: symbol, in: framework, headers: headers)
            ?? "\(symbol) is not declared in the headers of \(framework.name).framework; "
            + "apelin_sdk_analyze_framework with symbol_filter shows whether its .tbd exports it"
    }

    /// Where `symbol` is declared among `headers`, each declaring line with
    /// its number; with one header, its text after them. Nil when none
    /// declares it. A header that leaves the SDK, is not a regular file or
    /// is over the size limit is passed over.
    private func declarations(of symbol: String, in framework: Location, headers: [String]) -> String? {
        let pattern = HeaderDeclarations(symbol)
        var found: [(header: String, lines: [String])] = []
        var firstText = ""
        for header in headers.prefix(Self.maxScannedHeaders) {
            guard let path = try? sdk.resolveExisting("\(framework.path)/Headers/\(header)"),
                  let text = try? readSDKText(path, limit: Self.maxHeaderBytes) else { continue }
            let lines = pattern.lines(in: text)
            guard !lines.isEmpty else { continue }
            if found.isEmpty {
                firstText = text
            }
            found.append((header, lines))
        }
        guard !found.isEmpty else { return nil }
        let scanned = headers.count > Self.maxScannedHeaders
            ? " (the first \(Self.maxScannedHeaders) of \(headers.count) headers searched)"
            : ""
        if found.count == 1, let only = found.first {
            let lines = Self.listed(only.lines.map { "  \($0)" })
            return "\(symbol) is declared in \(only.header)\(scanned):\n\(lines)\n\n\(firstText)"
        }
        let lines = found.flatMap { entry in entry.lines.map { "  \(entry.header):\($0)" } }
        return "\(symbol) is declared in \(found.count) headers\(scanned); read one with header:\n"
            + Self.listed(lines)
    }

    /// The first `maxListedDeclarations` lines, and how many more there are.
    private static func listed(_ lines: [String]) -> String {
        var listed = lines.prefix(maxListedDeclarations).joined(separator: "\n")
        if lines.count > maxListedDeclarations {
            listed += "\n  … \(lines.count - maxListedDeclarations) more"
        }
        return listed
    }

    private func noHeaders(_ framework: Location) -> String {
        "\(framework.name).framework has no headers in this SDK; apelin_sdk_analyze_framework lists the "
            + "classes and symbols its .tbd exports: declare the interface you call in a local header"
    }

    // MARK: - Helpers

    private func frameworkName(_ arguments: JSONValue) throws -> String {
        var name = try arguments.requireString("framework")
        if name.hasSuffix(".framework") {
            name = String(name.dropLast(".framework".count))
        }
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), !name.hasPrefix(".") else {
            throw ToolArgumentError("framework must be a name like UIKit")
        }
        return name
    }

    private func headerNames(_ framework: String) -> [String] {
        guard let headers = try? sdk.resolveExisting("\(framework)/Headers"),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: headers) else { return [] }
        return entries.filter { $0.hasSuffix(".h") }.sorted()
    }

    private func readSDKText(_ canonical: String, limit: Int) throws -> String {
        guard sdk.contains(canonical) else { throw PathPolicyError.outsideRoot(canonical) }
        let url = URL(fileURLWithPath: canonical)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw PathPolicyError.notAFile(sdk.relative(canonical)) }
        guard (values.fileSize ?? 0) <= limit else {
            throw ToolArgumentError("\(sdk.relative(canonical)) is too large")
        }
        return try String(decoding: Data(contentsOf: url), as: UTF8.self)
    }

    static func isIdentifier(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,255}$"#, options: .regularExpression) != nil
    }
}

/// The lines of a header that declare one name: an Objective-C class or
/// protocol (not a category, an extension or a forward declaration), a
/// typedef, struct, union or enum or one of an enum's constants, a macro, a
/// C function or an exported constant. A line that only uses the name, as a
/// superclass, a parameter or a property's type, is not one, nor is a
/// comment. Read line by line, as Apple's SDK headers are written, with no
/// C parser behind it.
struct HeaderDeclarations {
    let symbol: String
    private let expression: NSRegularExpression?

    init(_ symbol: String) {
        self.symbol = symbol
        let name = NSRegularExpression.escapedPattern(for: symbol)
        let forms = [
            #"@interface\s+NAME\b(?!\s*\()"#,
            #"@protocol\s+NAME\b(?!\s*[;,])"#,
            // typedef … NAME; typedef NS_ENUM(…, NAME); typedef … (^NAME)(…);
            // typedef … NAME API_AVAILABLE(…);
            #"^\s*typedef\b.*[\s*,(^]NAME\s*(?:;|\)|MACRO)"#,
            // The closing line of a typedef'd struct or enum.
            #"^\s*\}\s*NAME\b"#,
            #"\b(?:struct|union|enum)\s+NAME\s*(?::\s*\w+\s*)?(?:\{|$)"#,
            // An enum's constant, indented inside its braces: NAME,
            // NAME = 1 << 0, NAME API_AVAILABLE(…),
            #"^\s+NAME\s*(?:=|,|$|MACRO)"#,
            #"^\s*#\s*define\s+NAME\b"#,
            #"^\s*(?!return\b|typedef\b)(?:[A-Za-z_][\w\s*]*?[\s*])?NAME\s*\("#,
            #"^\s*\w*(?:extern|EXTERN|EXPORT|static)\b[\w\s*]*?[\s*]NAME\s*(?:;|\[|=|$|MACRO)"#,
        ]
        // MACRO: an attribute after the name, as in NAME API_AVAILABLE(…) or
        // NAME NS_TYPED_ENUM; — not a return type before a function's name.
        let pattern = forms.joined(separator: "|")
            .replacingOccurrences(of: "MACRO", with: #"\s[A-Z_][A-Z0-9_]+\s*(?:\(|;|,|$)"#)
            .replacingOccurrences(of: "NAME", with: name)
        expression = try? NSRegularExpression(pattern: pattern)
    }

    /// `"<line number>: <line>"` for each declaring line of `text`.
    func lines(in text: String) -> [String] {
        guard let expression, text.contains(symbol) else { return [] }
        var lines: [String] = []
        var inComment = false
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let code = Self.code(of: line, inComment: &inComment)
            guard code.contains(symbol),
                  expression.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
            else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            lines.append("\(index + 1): \(trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed)")
        }
        return lines
    }

    /// `line` without its comments; `inComment` carries a block comment
    /// from one line to the next.
    static func code(of line: String, inComment: inout Bool) -> String {
        guard inComment || line.contains("/") else { return line }
        var code = ""
        var rest = line[...]
        while !rest.isEmpty {
            if inComment {
                guard let end = rest.range(of: "*/") else { return code }
                rest = rest[end.upperBound...]
                inComment = false
                continue
            }
            let block = rest.range(of: "/*")
            if let slashes = rest.range(of: "//"), block.map({ slashes.lowerBound < $0.lowerBound }) ?? true {
                return code + String(rest[..<slashes.lowerBound])
            }
            guard let block else { return code + String(rest) }
            // A comment between two words still parts them.
            code += String(rest[..<block.lowerBound]) + " "
            rest = rest[block.upperBound...]
            inComment = true
        }
        return code
    }
}

/// The parts of a text-based stub (`.tbd`, v3/v4 YAML or v5 JSON) the agent
/// needs.
struct TBDStub: Equatable {
    var installName: String?
    var currentVersion: String?
    var targets: [String] = []
    var reexports: [String] = []
    var symbols: [String] = []
    var objcClasses: [String] = []

    static func parse(_ text: String) -> TBDStub {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let stub = parseJSON(trimmed) {
            return stub
        }
        return parseYAML(text)
    }

    private static func parseYAML(_ text: String) -> TBDStub {
        var stub = TBDStub()
        stub.installName = scalar("install-name", in: text)
        stub.currentVersion = scalar("current-version", in: text)
        stub.targets = unique(lists("targets", in: text))
        if stub.targets.isEmpty {
            stub.targets = unique(lists("archs", in: text))
        }
        stub.reexports = unique(
            lists("re-exports", in: text) + lists("reexported-libraries", in: text).filter { $0.hasPrefix("/") },
        )
        // Only the exports sections, not undefineds.
        let exports = sections(of: text, named: ["exports:", "reexports:"])
        stub.symbols = unique(
            lists("symbols", in: exports)
                + lists("weak-symbols", in: exports)
                + lists("thread-local-symbols", in: exports),
        )
        stub.objcClasses = unique(lists("objc-classes", in: exports))
        return stub
    }

    private static func parseJSON(_ text: String) -> TBDStub? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return nil
        }
        let library = (object["main_library"] as? [String: Any]) ?? object
        var stub = TBDStub()
        stub.installName = ((library["install_names"] as? [[String: Any]])?.first?["name"]) as? String
        stub.currentVersion = ((library["current_versions"] as? [[String: Any]])?.first?["version"]) as? String
        stub.targets = ((library["target_info"] as? [[String: Any]]) ?? []).compactMap { $0["target"] as? String }
        stub.reexports = ((library["reexported_libraries"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["names"] as? [String]) ?? [] }
        var symbols: [String] = []
        var classes: [String] = []
        for entry in (library["exported_symbols"] as? [[String: Any]]) ?? [] {
            for key in ["data", "text"] {
                guard let group = entry[key] as? [String: Any] else { continue }
                symbols += (group["global"] as? [String]) ?? []
                symbols += (group["weak"] as? [String]) ?? []
                classes += (group["objc_class"] as? [String]) ?? []
            }
        }
        stub.symbols = unique(symbols)
        stub.objcClasses = unique(classes)
        return stub
    }

    /// The text from each `name` line to the next top-level key.
    private static func sections(of text: String, named names: [String]) -> String {
        var output = ""
        var inside = false
        for line in text.components(separatedBy: "\n") {
            let isTopLevel = !line.hasPrefix(" ") && !line.hasPrefix("-") && line.contains(":")
            if isTopLevel {
                inside = names.contains { line.hasPrefix($0) }
            }
            if inside {
                output += line + "\n"
            }
        }
        return output
    }

    private static func scalar(_ key: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard stripped.hasPrefix("\(key):") else { continue }
            let value = stripped.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            return unquote(value)
        }
        return nil
    }

    /// Every `[ … ]` list that follows `key:`, across lines.
    private static func lists(_ key: String, in text: String) -> [String] {
        var values: [String] = []
        var search = text.startIndex
        let needle = "\(key):"
        while let found = text.range(of: needle, range: search ..< text.endIndex) {
            // Must be a whole key: preceded by start, space, '-' or newline.
            if found.lowerBound > text.startIndex {
                let before = text[text.index(before: found.lowerBound)]
                if !(before == " " || before == "\n" || before == "-" || before == "\t") {
                    search = found.upperBound
                    continue
                }
            }
            guard let open = text[found.upperBound...].firstIndex(where: { !$0.isWhitespace }), text[open] == "[",
                  let close = text[open...].firstIndex(of: "]")
            else {
                search = found.upperBound
                continue
            }
            let body = text[text.index(after: open) ..< close]
            values += body.split(separator: ",")
                .map { unquote($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { !$0.isEmpty }
            search = close
        }
        return values
    }

    private static func unquote(_ value: String) -> String {
        var value = value
        if value.count >= 2, let first = value.first, first == "'" || first == "\"", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
