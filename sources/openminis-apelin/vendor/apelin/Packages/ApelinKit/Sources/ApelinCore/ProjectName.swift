/// A project's name is its directory under `Projects/`: one path component.
/// Renaming moves the directory; the project's ID lives in
/// `apelin-project.json` and does not change.
public enum ProjectName {
    public enum Problem: String, Codable, Sendable, Equatable {
        case empty
        case tooLong
        case containsSlash
        case containsNUL
        case containsControlCharacter
        case dotName
        case leadingDot

        /// The sentence a person reads when a name is refused.
        public var reason: String {
            switch self {
            case .empty: "Enter a project name."
            case .tooLong: "The project name is too long. Use a shorter name."
            case .containsSlash: "The project name cannot contain “/”."
            case .leadingDot, .dotName: "The project name cannot start with a dot."
            case .containsNUL, .containsControlCharacter: "The project name contains a character that is not allowed."
            }
        }
    }

    /// Longest name in UTF-8 bytes: one path component on APFS.
    public static let maximumLength = 255

    /// Nil when the name is acceptable, otherwise the first rule it breaks.
    public static func validate(_ name: String) -> Problem? {
        if name.isEmpty {
            return .empty
        }
        if name.utf8.contains(0) {
            return .containsNUL
        }
        if name.utf8.count > maximumLength {
            return .tooLong
        }
        if name.contains("/") {
            return .containsSlash
        }
        if name == "." || name == ".." {
            return .dotName
        }
        if name.hasPrefix(".") {
            return .leadingDot
        }
        if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return .containsControlCharacter
        }
        return nil
    }
}
