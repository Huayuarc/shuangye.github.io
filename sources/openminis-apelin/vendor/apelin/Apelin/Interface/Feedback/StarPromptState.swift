import Foundation

/// Where the star prompt stands (owner, 2026-10-29): the builds counted
/// since it last asked, how many times it has asked, when it last asked
/// GitHub whether the account has starred Apelin, and whether it is done.
/// It asks after ten builds, and after ten more each time the reader
/// answers Maybe Later, three times at most; it asks GitHub at most once a
/// day. Star Now, or an account that has starred Apelin already, ends it
/// for good.
struct StarPromptState: Codable, Equatable {
    static let buildsBetweenAsks = 10
    static let maximumAsks = 3
    static let checkInterval: TimeInterval = 24 * 60 * 60

    var builds = 0
    var timesAsked = 0
    var lastCheck: Date?
    var isDone = false

    /// Whether it may still ask at all.
    var isOpen: Bool {
        !isDone && timesAsked < Self.maximumAsks
    }

    /// Whether it is time to ask GitHub, and then the reader: enough
    /// builds since it last asked, and a day since it last asked GitHub
    /// (or a clock set back past that).
    func mayCheck(at now: Date) -> Bool {
        guard isOpen, builds >= Self.buildsBetweenAsks else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= Self.checkInterval || now < lastCheck
    }

    mutating func count(_ completed: Int) {
        guard isOpen else { return }
        builds += completed
    }

    mutating func recordCheck(at now: Date) {
        lastCheck = now
    }

    /// It asked; the next ask is another ten builds away.
    mutating func recordAsk() {
        timesAsked += 1
        builds = 0
    }

    /// Star Now was tapped, or the account had starred Apelin already.
    mutating func finish() {
        isDone = true
    }
}
