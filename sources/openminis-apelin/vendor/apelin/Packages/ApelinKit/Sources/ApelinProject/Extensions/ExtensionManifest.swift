import Foundation

/// A development extension's `manifest.json`, version 1
/// (Documents/Schemas/README.md ▸ Extension manifest), typed. Read only
/// after `ManifestValidation` passed.
public struct ExtensionManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var id: String
    public var version: String
    public var kind: ProjectKind
    public var displayName: String
    public var summary: String
    public var apelinCompatibility: Compatibility
    public var requirements: Requirements
    public var support: [String: SupportComponent]?
    public var templates: [Template]
    public var provenance: [Provenance]
    public var licenses: [License]

    public struct Compatibility: Codable, Sendable, Equatable {
        public var minimumAppVersion: String
        public var projectSchemaVersions: [Int]
        public var manifestSchemaVersion: Int
    }

    public struct PerBootstrap<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
        public var rootless: Value?
        public var roothide: Value?

        public subscript(bootstrap: Bootstrap) -> Value? {
            switch bootstrap {
            case .rootless: rootless
            case .roothide: roothide
            }
        }
    }

    public struct Requirements: Codable, Sendable, Equatable {
        public var toolchainComponents: [String]
        public var languages: [ProjectLanguage]
        public var sdkFrameworks: [String]?
        public var bootstraps: [Bootstrap]
        public var architectures: PerBootstrap<[Architecture]>
        public var runtimeDependencies: PerBootstrap<[String]>?
    }

    public struct SupportComponent: Codable, Sendable, Equatable {
        public var summary: String
        public var includeDirectories: [String]?
        public var linkStubDirectories: PerBootstrap<String>?
        public var libraries: [String]?
        public var frameworks: [String]?
        public var rpaths: PerBootstrap<[String]>?
        public var installNames: PerBootstrap<String>?
        public var symbols: [String]?
        public var architectures: [Architecture]
        public var runtimeDependencies: PerBootstrap<[String]>?
        public var spdx: String
        public var license: String
    }

    public struct Parameter: Codable, Sendable, Equatable {
        public var name: String
        public var type: String
        public var label: String
        public var help: String?
        public var required: Bool?
        public var `default`: JSONDocumentBox?
        public var values: [String]?
        public var maxLength: Int?
    }

    public struct TemplateFile: Codable, Sendable, Equatable {
        public var path: String
        public var format: String
        public var mode: String?
    }

    public struct Template: Codable, Sendable, Equatable {
        public var id: String
        public var directory: String
        public var displayName: String
        public var summary: String
        public var language: ProjectLanguage
        public var toolchainComponents: [String]?
        public var project: String
        public var parameters: [Parameter]
        public var files: [TemplateFile]
        public var digest: String
    }

    public struct Provenance: Codable, Sendable, Equatable {
        public var scope: String
        public var origin: String
        public var repository: String?
        public var commit: String?
        public var paths: [String]?
        public var adaptations: [String]
    }

    public struct License: Codable, Sendable, Equatable {
        public var path: String
        public var spdx: String
        public var covers: [String]
    }

    public func template(_ id: String) -> Template? {
        templates.first { $0.id == id }
    }

    public init(document: JSONDocument) throws {
        self = try JSONDecoder().decode(ExtensionManifest.self, from: JSONWriter.compact(document))
    }
}

/// A JSON value inside a Codable model, kept exactly (a parameter's
/// `default` may be a string, a boolean, a list or an object).
public struct JSONDocumentBox: Codable, Sendable, Equatable {
    public var value: JSONDocument

    public init(_ value: JSONDocument) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        value = try JSONDocumentBox.decode(decoder.singleValueContainer())
    }

    private static func decode(_ container: SingleValueDecodingContainer) throws -> JSONDocument {
        if container.decodeNil() {
            return .null
        }
        if let flag = try? container.decode(Bool.self) {
            return .bool(flag)
        }
        if let number = try? container.decode(Int64.self) {
            return .integer(number)
        }
        if let text = try? container.decode(String.self) {
            return .string(text)
        }
        if let items = try? container.decode([JSONDocumentBox].self) {
            return .array(items.map(\.value))
        }
        let members = try container.decode([String: JSONDocumentBox].self)
        return .object(JSONObject(members.sorted { $0.key < $1.key }.map { ($0.key, $0.value.value) }))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .null: try container.encodeNil()
        case let .bool(flag): try container.encode(flag)
        case let .integer(number): try container.encode(number)
        case let .string(text): try container.encode(text)
        case let .array(items): try container.encode(items.map(JSONDocumentBox.init))
        case let .object(object):
            try container.encode(Dictionary(
                object.entries.map { ($0.key, JSONDocumentBox($0.value)) },
                uniquingKeysWith: { a, _ in a },
            ))
        }
    }
}

/// The manifest against its schema, then the rules beyond it: ported from
/// `validate_manifest` and `manifest_semantic_errors`, messages included.
public enum ManifestValidation {
    public static let schema = SchemaValidator(schema: try! StrictJSON.parse(Data(EmbeddedSchemas.manifest.utf8)))

    public static func errors(_ document: JSONDocument) -> [String] {
        let errors = schema.errors(document)
        guard errors.isEmpty else { return errors }
        do {
            return try semanticErrors(ExtensionManifest(document: document))
        } catch {
            return ["/: \(error)"]
        }
    }

    public static func semanticErrors(_ manifest: ExtensionManifest) -> [String] {
        var errors: [String] = []
        let ids = manifest.templates.map(\.id)
        if Set(ids).count != ids.count {
            errors.append("/templates: template ids must be unique")
        }
        for (index, template) in manifest.templates.enumerated() {
            if template.directory != "templates/\(template.id)" {
                errors.append("/templates/\(index)/directory: must be templates/\(template.id)")
            }
            let names = template.parameters.map(\.name)
            if Set(names).count != names.count {
                errors.append("/templates/\(index)/parameters: parameter names must be unique")
            }
            for name in names where TemplateParameters.builtin[name] != nil {
                errors.append("/templates/\(index)/parameters: \(name) is a built-in parameter")
            }
            let paths = template.files.map(\.path)
            if Set(paths).count != paths.count {
                errors.append("/templates/\(index)/files: a path is listed twice")
            }
            if !paths.contains("apelin-project.json") {
                errors.append("/templates/\(index)/files: apelin-project.json is not listed")
            }
            if !manifest.requirements.languages.contains(template.language) {
                errors.append("/templates/\(index)/language: not in requirements.languages")
            }
        }
        var scopes = Set(ids.map { "template:\($0)" })
        scopes.formUnion((manifest.support ?? [:]).keys.map { "support:\($0)" })
        scopes.insert("manifest")
        for (index, entry) in manifest.provenance.enumerated() where !scopes.contains(entry.scope) {
            errors.append("/provenance/\(index)/scope: names nothing in this manifest")
        }
        let covered = Set(manifest.licenses.flatMap(\.covers))
        for scope in scopes.subtracting(["manifest"]).sorted() where !covered.contains(scope) {
            errors.append("/licenses: nothing covers \(scope)")
        }
        for scope in covered.sorted() where !scopes.contains(scope) {
            errors.append("/licenses: \(scope) names nothing in this manifest")
        }
        let bootstraps = Set(manifest.requirements.bootstraps)
        let mapped = Set(Bootstrap.allCases.filter { manifest.requirements.architectures[$0] != nil })
        if mapped != bootstraps {
            errors.append("/requirements/architectures: must have exactly the bootstraps listed")
        }
        return errors
    }
}
