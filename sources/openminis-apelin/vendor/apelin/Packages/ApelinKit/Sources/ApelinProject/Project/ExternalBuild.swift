import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// Whether an `apelin-project.json` is a workspace's: `kind` `workspace` or
/// `buildSystem` `external`. A workspace has an identity and no description
/// apelin-build builds from; the agent reads the same rule
/// (`ProjectBuildSystem`).
public enum Workspace {
    public static func isWorkspace(_ manifest: JSONDocument) -> Bool {
        manifest["kind"]?.stringValue == "workspace" || manifest["buildSystem"]?.stringValue == "external"
    }

    /// The manifest of the project folder `root` when it is a workspace's;
    /// nil for a project with a description, or a manifest that does not
    /// read (its check then says why).
    public static func manifest(at root: URL) -> JSONDocument? {
        guard let data = try? ProjectFiles.read(ProjectStore.projectFileName, in: root),
              let document = try? StrictJSON.parse(data),
              isWorkspace(document)
        else { return nil }
        return document
    }
}

/// A workspace's own build (owner, 2026-10-23): the script apelin-build runs
/// for it, declared under `external` in its `apelin-project.json`. The
/// repository keeps its own way of building — a Makefile, a shell script —
/// and Apelin takes from there the one `.deb` the script writes into
/// `APELIN_PACKAGE_DIR`: checked, registered as the build's artifact, and
/// installed through the session host's bridge like any other.
///
/// ```json
/// "external": { "script": "scripts/apelin-build.sh", "interpreter": "sh", "arguments": ["--fast"] }
/// ```
///
/// `interpreter` defaults to `sh`; `arguments` to none. The script is a
/// regular file inside the project, by canonical path.
public struct ExternalBuildDeclaration: Sendable, Equatable {
    public var script: String
    public var interpreter: ProjectDocument.ScriptInterpreter
    public var arguments: [String]

    public static let member = "external"
    static let maximumArguments = 32
    static let maximumArgumentLength = 1024

    public init(script: String, interpreter: ProjectDocument.ScriptInterpreter = .sh, arguments: [String] = []) {
        self.script = script
        self.interpreter = interpreter
        self.arguments = arguments
    }

    /// The declaration in a workspace's manifest, its script found inside
    /// `root`; nil when the manifest declares none. A declaration that is
    /// malformed, or names a script that is not a regular file in the
    /// project, is an error naming the field.
    public static func read(_ manifest: JSONDocument, root: URL) throws -> ExternalBuildDeclaration? {
        guard let value = manifest[member] else { return nil }
        guard let object = value.objectValue else { throw invalid("/external", "must be an object") }
        for key in object.keys where !["script", "interpreter", "arguments"].contains(key) {
            throw invalid("/external/\(key)", "is not a member; external takes script, interpreter and arguments")
        }
        guard let script = value["script"]?.stringValue else {
            throw invalid("/external/script", "is required: the project file that builds the package")
        }
        guard isPlainRelative(script) else {
            throw invalid("/external/script", "must be a path inside the project, such as scripts/build.sh")
        }
        do {
            let path = try ProjectFiles.resolve(script, in: root)
            var info = stat()
            guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw ProjectFiles.Refused(description: "\(script) is not a regular file")
            }
        } catch {
            throw invalid("/external/script", "\(error)")
        }
        var interpreter = ProjectDocument.ScriptInterpreter.sh
        if let name = value["interpreter"] {
            guard let parsed = name.stringValue.flatMap(ProjectDocument.ScriptInterpreter.init(rawValue:)) else {
                throw invalid("/external/interpreter", "must be sh, bash, zsh, python3 or perl")
            }
            interpreter = parsed
        }
        var arguments: [String] = []
        if let list = value["arguments"] {
            guard let items = list.arrayValue, items.count <= maximumArguments else {
                throw invalid("/external/arguments", "must be a list of at most \(maximumArguments) strings")
            }
            for (index, item) in items.enumerated() {
                guard let argument = item.stringValue, argument.utf8.count <= maximumArgumentLength,
                      !CanonicalPath.containsNUL(argument), !argument.contains("\n")
                else {
                    throw invalid("/external/arguments/\(index)", "must be one line of at most \(maximumArgumentLength) bytes")
                }
                arguments.append(argument)
            }
        }
        return ExternalBuildDeclaration(script: script, interpreter: interpreter, arguments: arguments)
    }

    /// No empty component, none starting with `.`, no leading `/`: so `.`,
    /// `..` and a hidden folder cannot be spelled, as the description's own
    /// project paths.
    private static func isPlainRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !CanonicalPath.containsNUL(path) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    private static func invalid(_ field: String, _ problem: String) -> ApelinError {
        ApelinError(.badRequest, "apelin-project.json: \(field) \(problem)")
    }
}
