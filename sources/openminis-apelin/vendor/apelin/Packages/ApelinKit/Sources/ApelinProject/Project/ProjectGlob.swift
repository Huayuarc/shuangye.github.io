import ApelinCore
import Foundation

/// A project glob (README ▸ Common rules): `*` and `?` within a component,
/// `**` for any depth. Hidden files never match; every match is resolved
/// and refused unless it is still inside the project.
public enum ProjectGlob {
    public struct Match: Sendable, Equatable {
        /// As the project would spell it.
        public var relative: String
        /// Canonical, inside the project.
        public var path: String
    }

    /// Every regular file under `root` matching any of `patterns`, in
    /// pattern order and then by path, each once.
    public static func expand(_ patterns: [String], in root: URL) throws -> [Match] {
        guard let realRoot = CanonicalPath.resolve(root.path) else {
            throw ProjectFiles.Refused(description: "\(root.path) does not resolve")
        }
        let files = allFiles(under: realRoot)
        var seen: Set<String> = []
        var result: [Match] = []
        for pattern in patterns {
            let parts = pattern.split(separator: "/").map(String.init)
            for relative in files where matches(parts[...], relative.split(separator: "/").map(String.init)[...])
                && !seen.contains(relative)
            {
                guard let real = CanonicalPath.resolve(realRoot + "/" + relative),
                      CanonicalPath.isCanonical(real, inside: realRoot)
                else {
                    throw ProjectFiles.Refused(description: "\(relative) resolves outside the project")
                }
                var info = stat()
                guard stat(real, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
                seen.insert(relative)
                result.append(Match(relative: relative, path: real))
            }
        }
        return result
    }

    /// Matches for one pattern; empty when it matches nothing.
    public static func expand(_ pattern: String, in root: URL) throws -> [Match] {
        try expand([pattern], in: root)
    }

    private static func allFiles(under root: String) -> [String] {
        var out: [String] = []
        guard let walker = FileManager.default.enumerator(atPath: root) else { return out }
        while let relative = walker.nextObject() as? String {
            let components = relative.split(separator: "/")
            if components.contains(where: { $0.hasPrefix(".") }) {
                walker.skipDescendants()
                continue
            }
            var info = stat()
            guard lstat(root + "/" + relative, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFREG || kind == S_IFLNK {
                out.append(relative)
            }
        }
        return out.sorted()
    }

    static func matches(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard let head = pattern.first else { return path.isEmpty }
        if head == "**" {
            var rest = path
            while true {
                if matches(pattern.dropFirst(), rest) {
                    return true
                }
                guard !rest.isEmpty else { return false }
                rest = rest.dropFirst()
            }
        }
        guard let component = path.first, fnmatch(head, component, 0) == 0 else { return false }
        return matches(pattern.dropFirst(), path.dropFirst())
    }
}
