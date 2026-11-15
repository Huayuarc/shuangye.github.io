import Darwin
import Foundation

/// Paths are canonicalised before anything is decided about them:
/// `realpath(3)` first, then a comparison by components. An embedded NUL is
/// refused before either.
public enum CanonicalPath {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case embeddedNUL
        case unresolvable(String, Int32)

        public var description: String {
            switch self {
            case .embeddedNUL: "the path contains a NUL byte"
            case let .unresolvable(path, code): "\(path): \(String(cString: strerror(code)))"
            }
        }
    }

    public static func resolve(_ path: String) throws -> String {
        guard !path.utf8.contains(0) else { throw Failure.embeddedNUL }
        guard let resolved = realpath(path, nil) else { throw Failure.unresolvable(path, errno) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether `path` is `root` or below it, both already canonical.
    public static func isInside(_ path: String, root: String) -> Bool {
        let pathComponents = path.split(separator: "/", omittingEmptySubsequences: true)
        let rootComponents = root.split(separator: "/", omittingEmptySubsequences: true)
        return pathComponents.count >= rootComponents.count
            && zip(pathComponents, rootComponents).allSatisfy { $0 == $1 }
    }

    /// Whether a relative path stays relative and never climbs: no leading
    /// slash, no `..`, no empty or `.` component, no NUL.
    public static func isPlainRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
