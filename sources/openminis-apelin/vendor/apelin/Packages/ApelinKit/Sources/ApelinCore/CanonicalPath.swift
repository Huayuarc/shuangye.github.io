import Darwin

/// Every path is canonicalised before a decision is made about it: an
/// embedded NUL is rejected first, then `realpath(3)`, then components are
/// compared — never string prefixes.
public enum CanonicalPath {
    /// Whether the string carries a NUL, which C would read as an earlier end.
    public static func containsNUL(_ path: String) -> Bool {
        path.utf8.contains(0)
    }

    /// `realpath(3)`; nil for a path with an embedded NUL or one that does not
    /// resolve.
    public static func resolve(_ path: String) -> String? {
        guard !containsNUL(path), let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The path's components, without empty ones (`//`) and without `.`.
    public static func components(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
    }

    /// Whether `path` is `root` or lies under it, both already canonical.
    /// Components are compared, so `/a/bc` is not inside `/a/b`.
    public static func isCanonical(_ path: String, inside root: String) -> Bool {
        let pathComponents = components(path)
        let rootComponents = components(root)
        guard pathComponents.count >= rootComponents.count else { return false }
        return zip(pathComponents, rootComponents).allSatisfy { $0 == $1 }
    }

    /// Resolves both and answers whether `path` is inside `root`. A path that
    /// does not resolve is never inside anything.
    public static func resolved(_ path: String, isInside root: String) -> Bool {
        guard let path = resolve(path), let root = resolve(root) else { return false }
        return isCanonical(path, inside: root)
    }

    /// A relative path that stays where it is put: no NUL, not absolute, no
    /// `..`, no empty string. Resolve the joined path afterwards anyway — a
    /// symlink on disk can still lead out.
    public static func isPlainRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !containsNUL(path), !path.hasPrefix("/") else { return false }
        return !components(path).contains("..")
    }
}
