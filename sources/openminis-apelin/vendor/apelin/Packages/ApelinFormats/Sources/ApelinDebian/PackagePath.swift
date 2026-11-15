import Foundation

/// The two spellings of a path inside a package.
///
/// A tar member is relative (`Applications/X.app`, maybe `./`-prefixed) and
/// what dpkg lists is absolute (`/Applications/X.app`). Both are refused
/// rather than repaired when they could escape the root or carry a byte no
/// filesystem path can.
public enum PackagePath {
    /// A tar member name as dpkg names it: leading `./` and `.` components
    /// dropped, no leading slash, no `..`, no NUL or newline. The root itself
    /// comes back empty.
    ///
    /// From Irisin (MIT, OwnGoal Studio): `PreparedPackage.relativePath`.
    public static func relative(_ original: String) throws -> String {
        guard original.utf8.first != 0x2F, !carriesForbiddenByte(original) else {
            throw PackageFormatError.invalidPath(original.debugDescription)
        }
        let components = original.utf8.split(separator: 0x2F).filter { !$0.elementsEqual(".".utf8) }
        guard !components.contains(where: { $0.elementsEqual("..".utf8) }) else {
            throw PackageFormatError.invalidPath(original.debugDescription)
        }
        return components.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
    }

    /// The components of a canonical absolute path: it starts with `/`, has
    /// no empty, `.` or `..` component, no trailing slash, and no NUL or
    /// newline. `/` itself is the empty list.
    public static func components(ofAbsolute path: String) throws -> [String] {
        guard path.utf8.first == 0x2F, !carriesForbiddenByte(path) else {
            throw PackageFormatError.invalidPath(path.debugDescription)
        }
        if path == "/" {
            return []
        }
        let components = path.utf8.dropFirst().split(separator: 0x2F, omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && !$0.elementsEqual(".".utf8) && !$0.elementsEqual("..".utf8) })
        else {
            throw PackageFormatError.invalidPath(path.debugDescription)
        }
        return components.map { String(decoding: $0, as: UTF8.self) }
    }

    /// True when `name` can be one path component: not empty, not `.` or
    /// `..`, and no slash, NUL or newline.
    public static func isValidComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.utf8.contains(0x2F) && !carriesForbiddenByte(name)
    }

    /// A NUL or a newline, which no path inside a package may hold.
    private static func carriesForbiddenByte(_ text: String) -> Bool {
        text.utf8.contains(0) || text.utf8.contains(0x0A)
    }
}
