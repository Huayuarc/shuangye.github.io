import Foundation

public enum ProjectDisplayName {
    public static let maximumLength = 80

    /// A model's title is a candidate, never a path or an executable name.
    public static func candidate(_ text: String) -> String? {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let value = String(words.prefix(8).joined(separator: " ").prefix(maximumLength))
            .trimmingCharacters(in: .whitespaces)
        return isValid(value) ? value : nil
    }

    public static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.count <= maximumLength
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
