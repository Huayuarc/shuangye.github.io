import Foundation

/// The star prompt asks after ten builds, again ten builds after each Maybe
/// Later, three times at most, asks GitHub at most once a day, and never
/// again once the reader starred or the account had.
func checkStarPromptState() {
    let day = StarPromptState.checkInterval
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var state = StarPromptState()
    state.count(9)
    precondition(!state.mayCheck(at: start), "nine builds are not enough")
    state.count(1)
    precondition(state.mayCheck(at: start), "the tenth is")

    // GitHub did not answer: not again that day, whatever is built
    state.recordCheck(at: start)
    state.count(5)
    precondition(!state.mayCheck(at: start.addingTimeInterval(day - 60)), "once a day")
    precondition(state.mayCheck(at: start.addingTimeInterval(day)), "the next day")
    precondition(state.mayCheck(at: start.addingTimeInterval(-60)), "a clock set back does not hold it")

    // Maybe Later, three times
    var later = state
    for ask in 1 ... StarPromptState.maximumAsks {
        let now = start.addingTimeInterval(Double(ask) * day)
        precondition(later.mayCheck(at: now), "ask \(ask) is due")
        later.recordCheck(at: now)
        later.recordAsk()
        precondition(later.builds == 0 && later.timesAsked == ask)
        later.count(9)
        precondition(!later.mayCheck(at: now.addingTimeInterval(2 * day)), "ten builds after a Maybe Later, not nine")
        later.count(1)
    }
    precondition(!later.isOpen && !later.mayCheck(at: start.addingTimeInterval(30 * day)), "three asks at most")
    later.count(10)
    precondition(later.builds == 0, "a closed prompt counts nothing more")

    // Star Now, or a star already there
    var starred = state
    starred.finish()
    starred.count(100)
    precondition(!starred.isOpen && !starred.mayCheck(at: start.addingTimeInterval(9 * day)), "never again")

    // kept in the app's defaults as JSON
    let saved = try! JSONDecoder().decode(StarPromptState.self, from: JSONEncoder().encode(later))
    precondition(saved == later)
    print("ok: the star prompt asks after ten builds, three times at most, and checks GitHub at most once a day")
}
