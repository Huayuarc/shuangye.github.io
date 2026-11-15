import Foundation
import Runestone
import TreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterJSON
import TreeSitterMake
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterObjC
import TreeSitterPython
import TreeSitterRuby
import TreeSitterSwift
import TreeSitterXML
import TreeSitterYAML

/// The query sources, one `<Language>Queries.swift` each under `Queries/`.
enum RunestoneQueries {}

/// Every language the editor highlights, and the one place a file is matched
/// to one. A file this does not name opens as plain text.
public enum RunestoneLanguage: String, CaseIterable, Sendable {
    case c
    case cpp
    case objc
    case swift
    case bash
    case python
    case ruby
    case json
    case yaml
    case markdown
    case markdownInline
    case xml
    case make

    /// The language for a file, by its whole name first (`Makefile`,
    /// `Podfile`, a package's `control`), then by its extension, compared
    /// without case.
    public init?(fileName: String) {
        let name = (fileName as NSString).lastPathComponent
        if let language = Self.byFileName[name] {
            self = language
            return
        }
        let pathExtension = (name as NSString).pathExtension.lowercased()
        guard !pathExtension.isEmpty, let language = Self.byExtension[pathExtension] else {
            return nil
        }
        self = language
    }

    /// The language an injection names: a Markdown fence's info string, or
    /// an `injection.language` a query sets. Compared without case.
    public init?(injectionName: String) {
        guard let language = Self.byInjectionName[injectionName.lowercased()] else {
            return nil
        }
        self = language
    }

    /// A new `TreeSitterLanguage`; its queries compile on first use. Keep
    /// one per language rather than asking again for every file.
    public var treeSitterLanguage: TreeSitterLanguage {
        TreeSitterLanguage(
            grammar,
            highlightsQuery: TreeSitterLanguage.Query(string: highlightsQuery),
            injectionsQuery: injectionsQuery.map { TreeSitterLanguage.Query(string: $0) },
            indentationScopes: indentationScopes
        )
    }
}

extension RunestoneLanguage {
    var grammar: UnsafePointer<TSLanguage> {
        switch self {
        case .c: tree_sitter_c()
        case .cpp: tree_sitter_cpp()
        case .objc: tree_sitter_objc()
        case .swift: tree_sitter_swift()
        case .bash: tree_sitter_bash()
        case .python: tree_sitter_python()
        case .ruby: tree_sitter_ruby()
        case .json: tree_sitter_json()
        case .yaml: tree_sitter_yaml()
        case .markdown: tree_sitter_markdown()
        case .markdownInline: tree_sitter_markdown_inline()
        case .xml: tree_sitter_xml()
        case .make: tree_sitter_make()
        }
    }

    var highlightsQuery: String {
        switch self {
        case .c: RunestoneQueries.cHighlights
        case .cpp: RunestoneQueries.cppHighlights
        case .objc: RunestoneQueries.objcHighlights
        case .swift: RunestoneQueries.swiftHighlights
        case .bash: RunestoneQueries.bashHighlights
        case .python: RunestoneQueries.pythonHighlights
        case .ruby: RunestoneQueries.rubyHighlights
        case .json: RunestoneQueries.jsonHighlights
        case .yaml: RunestoneQueries.yamlHighlights
        case .markdown: RunestoneQueries.markdownHighlights
        case .markdownInline: RunestoneQueries.markdownInlineHighlights
        case .xml: RunestoneQueries.xmlHighlights
        case .make: RunestoneQueries.makeHighlights
        }
    }

    var injectionsQuery: String? {
        switch self {
        case .markdown: RunestoneQueries.markdownInjections
        case .markdownInline: RunestoneQueries.markdownInlineInjections
        case .make: RunestoneQueries.makeInjections
        default: nil
        }
    }

    /// Upstream's (TreeSitterLanguages') indentation rules; Objective-C
    /// takes C's, the grammar it extends.
    var indentationScopes: TreeSitterIndentationScopes? {
        switch self {
        case .c, .objc:
            TreeSitterIndentationScopes(
                indent: ["compound_statement", "parameter_list", "initializer_list"],
                outdent: ["}"]
            )
        case .swift:
            TreeSitterIndentationScopes(
                indent: [
                    "protocol_body", "class_body", "computed_property", "computed_getter",
                    "computed_setter", "function_body", "if_statement", "lambda_literal",
                    "array_literal", "dictionary_literal", "switch_entry",
                ],
                outdent: ["else", "}", "]"]
            )
        case .bash:
            TreeSitterIndentationScopes(
                indent: [
                    "if_statement", "else", "while_statement", "for_statement",
                    "function_definition", "do_group",
                ],
                outdent: ["fi", "done"]
            )
        case .python:
            TreeSitterIndentationScopes(
                indent: [
                    "function_definition", "for_statement", "class_definition", "elif_clause",
                    "else_clause", "except_clause", "while_statement", "if_statement", "try_statement",
                ],
                whitespaceDenotesBlocks: true
            )
        case .ruby:
            TreeSitterIndentationScopes(
                indent: [
                    "class", "method", "singleton_method", "module", "call", "if", "block",
                    "do_block", "hash", "array", "argument_list", "case", "def", "while",
                ],
                inheritIndent: ["elsif", "else"],
                outdent: ["else", "elsif"]
            )
        case .json:
            TreeSitterIndentationScopes(indent: ["object", "array"], outdent: ["}", "]"])
        case .cpp, .yaml, .markdown, .markdownInline, .xml, .make:
            nil
        }
    }

    /// Files known by their whole name.
    static let byFileName: [String: RunestoneLanguage] = [
        "Makefile": .make, "makefile": .make, "GNUmakefile": .make,
        // CocoaPods, Bundler, fastlane and Rake read Ruby.
        "Podfile": .ruby, "Gemfile": .ruby, "Fastfile": .ruby, "Appfile": .ruby,
        "Matchfile": .ruby, "Pluginfile": .ruby, "Rakefile": .ruby,
        "Package.resolved": .json,
        // A package's control file reads as YAML's mappings, close enough to
        // colour its fields; Debian's maintainer scripts are shell.
        "control": .yaml,
        "preinst": .bash, "postinst": .bash, "prerm": .bash, "postrm": .bash, "extrainst_": .bash,
    ]

    /// Files known by their extension, lowercased.
    static let byExtension: [String: RunestoneLanguage] = [
        "c": .c,
        // A header is read as Objective-C, which is C and more: a tweak's
        // headers declare classes as often as functions.
        "h": .objc, "m": .objc, "mm": .objc,
        // Logos (Theos) is Objective-C with %directives; .xm and .xmi are its
        // Objective-C++ flavour, which the Objective-C grammar reads too.
        "x": .objc, "xm": .objc, "xi": .objc, "xmi": .objc,
        "cpp": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp,
        "swift": .swift,
        "sh": .bash, "bash": .bash, "zsh": .bash,
        "py": .python,
        "rb": .ruby, "podspec": .ruby, "gemspec": .ruby, "rake": .ruby,
        "json": .json, "xcstrings": .json,
        "yml": .yaml, "yaml": .yaml,
        "md": .markdown, "markdown": .markdown,
        "xml": .xml, "plist": .xml, "entitlements": .xml, "xcprivacy": .xml,
        "xib": .xml, "storyboard": .xml, "xcscheme": .xml,
        "mk": .make, "mak": .make,
    ]

    /// Names an injection may give, lowercased.
    static let byInjectionName: [String: RunestoneLanguage] = [
        "c": .c, "h": .c,
        "cpp": .cpp, "c++": .cpp, "cxx": .cpp, "hpp": .cpp,
        "objc": .objc, "objective-c": .objc, "objectivec": .objc, "obj-c": .objc,
        "objc++": .objc, "objective-c++": .objc, "m": .objc, "mm": .objc,
        "logos": .objc, "x": .objc, "xm": .objc,
        "swift": .swift,
        "bash": .bash, "sh": .bash, "shell": .bash, "zsh": .bash, "console": .bash,
        "python": .python, "py": .python, "python3": .python,
        "ruby": .ruby, "rb": .ruby,
        "json": .json,
        "yaml": .yaml, "yml": .yaml,
        "markdown": .markdown, "md": .markdown,
        "markdown_inline": .markdownInline,
        "xml": .xml, "plist": .xml,
        "make": .make, "makefile": .make, "mk": .make,
    ]
}

/// Hands `TreeSitterLanguageMode` the languages a document embeds — a
/// Markdown fence, its inline text, a Makefile's recipes — building each
/// once and keeping it.
public final class RunestoneLanguageProvider: TreeSitterLanguageProvider {
    private let lock = NSLock()
    private var languages: [RunestoneLanguage: TreeSitterLanguage] = [:]

    public init() {}

    public func treeSitterLanguage(named languageName: String) -> TreeSitterLanguage? {
        guard let language = RunestoneLanguage(injectionName: languageName) else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        if let treeSitterLanguage = languages[language] {
            return treeSitterLanguage
        }
        let treeSitterLanguage = language.treeSitterLanguage
        languages[language] = treeSitterLanguage
        return treeSitterLanguage
    }
}
