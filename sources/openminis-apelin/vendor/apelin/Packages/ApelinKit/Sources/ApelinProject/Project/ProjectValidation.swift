import Foundation

/// `apelin-project.json` against its schema, then the rules the schema
/// cannot say (Documents/Schemas/README.md, "beyond the schema"). Ported
/// from the reference implementation's `validate_project` and
/// `project_semantic_errors`, messages included.
public enum ProjectValidation {
    public static let schema = SchemaValidator(schema: try! StrictJSON.parse(Data(EmbeddedSchemas.project.utf8)))

    /// The schema as written, for a reader: the agent's apelin-project-description
    /// skill hands it to a model that asks.
    public static let schemaText = EmbeddedSchemas.project

    public static func errors(_ document: JSONDocument) -> [String] {
        let errors = schema.errors(document)
        guard errors.isEmpty else { return errors }
        do {
            return try semanticErrors(ProjectDocument(document: document))
        } catch {
            return ["/: \(error)"]
        }
    }

    /// Parses and validates; the typed document, or every error.
    public static func load(_ data: Data) throws -> (document: JSONDocument, project: ProjectDocument) {
        let document = try StrictJSON.parse(data)
        let problems = errors(document)
        guard problems.isEmpty else { throw ProjectInvalid(errors: problems) }
        return try (document, ProjectDocument(document: document))
    }

    private static let stepOrder = [
        "compile": 0, "link": 1, "bundle-resources": 2, "lipo": 3, "dsym": 4, "strip": 5, "sign": 6,
    ]

    public static func semanticErrors(_ project: ProjectDocument) -> [String] {
        var errors: [String] = []
        var products: [String: ProjectDocument.Product] = [:]
        for product in project.products where products[product.id] == nil {
            products[product.id] = product
        }
        if products.count != project.products.count {
            errors.append("/products: product ids must be unique")
        }
        let names = project.products.map(\.name)
        if Set(names).count != names.count {
            errors.append("/products: product names must be unique")
        }
        var seen: [String: [String]] = [:]
        var order: [String] = []
        for product in project.products where seen[product.id] == nil {
            seen[product.id] = []
            order.append(product.id)
        }
        var scriptIDs: Set<String> = []
        for (index, step) in project.build.steps.enumerated() {
            let location = "/build/steps/\(index)"
            if case let .script(id, _, _, _, _, _) = step {
                if scriptIDs.contains(id) {
                    errors.append("\(location): script id \(id) is used twice")
                }
                scriptIDs.insert(id)
                continue
            }
            let pid = step.product!
            guard let product = products[pid] else {
                errors.append("\(location): unknown product \(pid)")
                continue
            }
            let type = step.typeName
            let done = seen[pid]!
            if done.contains(type) {
                errors.append("\(location): \(type) appears twice for \(pid)")
            }
            if let last = done.last, stepOrder[type]! < stepOrder[last]! {
                errors.append("\(location): \(type) cannot follow \(last) for \(pid)")
            }
            if type == "bundle-resources", product.type != .app, product.type != .bundle {
                errors.append("\(location): bundle-resources is only for app and bundle products")
            }
            seen[pid]!.append(type)
        }
        for pid in order {
            let done = seen[pid]!
            for required in ["compile", "link", "lipo", "sign"] where !done.contains(required) {
                errors.append("/build/steps: \(pid) has no \(required) step")
            }
            if let type = products[pid]?.type, type == .app || type == .bundle, !done.contains("bundle-resources") {
                errors.append("/build/steps: \(pid) has no bundle-resources step")
            }
            if let last = done.last, last != "sign" {
                errors.append("/build/steps: sign must be the last step for \(pid)")
            }
        }
        let package = project.package
        for (index, entry) in package.layout.enumerated() {
            if let product = entry.product, products[product] == nil {
                errors.append("/package/layout/\(index): unknown product \(product)")
            }
        }
        let paths = package.layout.map(\.path)
        if Set(paths).count != paths.count {
            errors.append("/package/layout: two entries install to the same path")
        }
        for relation in package.depends ?? []
            where relation.split(separator: " ", omittingEmptySubsequences: false).first == "firmware"
        {
            errors.append("/package/depends: firmware is added from deploymentTarget by the packager")
        }
        if let filter = package.tweakFilter {
            if products[filter.dylib]?.type != .dylib {
                errors.append("/package/tweakFilter/dylib: must name a dylib product")
            } else if !package.layout.contains(where: {
                $0.product == filter.dylib && $0.path.hasPrefix(TweakFilterPlist.directory + "/")
            }) {
                errors.append("/package/tweakFilter: the dylib must be installed under /Library/MobileSubstrate/DynamicLibraries/")
            }
        }
        let bootstraps = Set(project.architectures.bootstraps)
        if let byBootstrap = package.dependsByBootstrap {
            for bootstrap in Bootstrap.allCases where byBootstrap[bootstrap] != nil && !bootstraps.contains(bootstrap) {
                errors.append("/package/dependsByBootstrap/\(bootstrap.rawValue): the project does not build for \(bootstrap.rawValue)")
            }
        }
        for (index, product) in project.products.enumerated() {
            let isSwift = project.language == .swift
            for source in product.sources {
                let suffix = pathExtension(source)
                if isSwift, suffix != ".swift" {
                    errors.append("/products/\(index)/sources: a Swift project compiles .swift sources only in v1")
                }
                if !isSwift, suffix != ".c", suffix != ".m" {
                    errors.append("/products/\(index)/sources: \(source) is not a .c or .m source")
                }
            }
        }
        return errors
    }

    /// `os.path.splitext(path)[1]`: the last component's extension with its
    /// dot, empty for none or for a leading-dot name.
    static func pathExtension(_ path: String) -> String {
        let name = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
        let trimmed = name.drop { $0 == "." }
        guard let dot = trimmed.lastIndex(of: ".") else { return "" }
        return String(trimmed[dot...])
    }
}

/// A project that failed validation, with every error.
public struct ProjectInvalid: Error, CustomStringConvertible, Sendable {
    public var errors: [String]
    public var description: String {
        errors.joined(separator: "; ")
    }
}

/// Where a tweak's filter plist goes and what it holds.
public enum TweakFilterPlist {
    public static let directory = "/Library/MobileSubstrate/DynamicLibraries"
}
