import Foundation

/// Everything the Debian side of this package throws, apart from the parsers
/// ported unchanged from Irisin (`DebianControl.parse` keeps its
/// `CocoaError(.fileReadCorruptFile)`).
///
/// The strings are for logs and diagnostics. A caller showing the user a
/// sentence maps the case to its own localized text.
public enum PackageFormatError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A path that is not one canonical absolute path: empty components, `.`
    /// or `..`, a NUL or a newline, or one already carrying a bootstrap
    /// prefix where a logical path was expected.
    case invalidPath(String)

    /// A control field that cannot be written as dpkg reads it back: a bad
    /// name, a value with a carriage return or NUL, a required field missing,
    /// a package name or version dpkg refuses.
    case invalidControl(String)

    /// Two entries for one path, a link without a target, a mode outside
    /// `0o7777`, a member name dpkg could not spell.
    case invalidEntry(String)

    /// The file is not a Debian binary package: no `debian-binary`, members
    /// out of order, a format version other than 2.0.
    case notDebianPackage(String)

    /// Refused before allocating or reading further.
    case tooLarge(String)

    /// libarchive's own message: *Truncated tar archive* says more than any
    /// sentence written here could.
    case archive(String)

    /// A syscall failed and left this `errno`.
    case system(errno: Int32, String)

    public var description: String {
        switch self {
        case let .invalidPath(detail): "invalid path: \(detail)"
        case let .invalidControl(detail): "invalid control file: \(detail)"
        case let .invalidEntry(detail): "invalid package entry: \(detail)"
        case let .notDebianPackage(detail): "not a Debian package: \(detail)"
        case let .tooLarge(detail): "too large: \(detail)"
        case let .archive(detail): "archive error: \(detail)"
        case let .system(code, detail): "\(detail): \(String(cString: strerror(code)))"
        }
    }
}
