import ApelinCore
import Foundation

/// A name the user touched is theirs, even when they type the suggestion again.
/// Until something is typed — or after it is all erased — the project takes
/// the generated fruit name, which opts into a later, agent-proposed manifest
/// display name.
struct ProjectCreationDraft {
    /// The generated name, used while nothing is typed.
    private(set) var suggestion: String
    private var typed = ""

    init(avoiding existing: [String] = []) {
        suggestion = Self.suggestion(avoiding: existing)
    }

    var automaticallyName: Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var name: String {
        automaticallyName ? suggestion : typed
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        ProjectName.validate(trimmedName) == nil
    }

    mutating func edit(_ name: String) {
        typed = name
    }

    mutating func avoidExisting(_ existing: [String]) {
        guard existing.contains(where: { $0.caseInsensitiveCompare(suggestion) == .orderedSame }) else { return }
        suggestion = Self.suggestion(avoiding: existing)
    }

    private static let fruits = [
        "Apple", "Apricot", "Avocado", "Banana", "Cherry", "Coconut", "Fig", "Grape",
        "Guava", "Kiwi", "Lemon", "Lime", "Lychee", "Mango", "Melon", "Nectarine",
        "Orange", "Papaya", "Peach", "Pear", "Pineapple", "Plum", "Raspberry", "Strawberry",
    ]

    private static func suggestion(avoiding existing: [String]) -> String {
        let occupied = Set(existing.map { $0.lowercased() })
        let available = fruits.filter { !occupied.contains($0.lowercased()) }
        if let name = available.randomElement() {
            return name
        }
        let fruit = fruits.randomElement() ?? "Apple"
        var suffix = 2
        while occupied.contains("\(fruit)\(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(fruit)\(suffix)"
    }
}
