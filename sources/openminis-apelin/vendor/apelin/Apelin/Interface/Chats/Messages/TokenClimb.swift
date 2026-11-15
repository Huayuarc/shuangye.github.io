import Foundation

/// How a summary's received-token figure climbs to the run's latest count
/// rather than jumping to it: straight from what it shows to the count,
/// arriving `running` (5 s) after the count came while the summary runs, and
/// `settling` (0.5 s) once the reply after it has begun. A count that comes
/// before the figure arrives sets off from where the figure is, so it never
/// goes back; asking again for the same count and pace keeps the time it was
/// first asked for. A lower count, which a run never sends, is shown at once.
struct TokenClimb: Equatable {
    static let running: TimeInterval = 5
    static let settling: TimeInterval = 0.5

    private(set) var target: Int
    private var start: Double
    private var startTime: TimeInterval
    private var duration: TimeInterval

    /// At rest on `value`.
    init(at value: Int) {
        target = value
        start = Double(value)
        startTime = 0
        duration = 0
    }

    /// Where the figure is at `time`, never past the count.
    func value(at time: TimeInterval) -> Double {
        let elapsed = time - startTime
        guard duration > 0, elapsed < duration else { return Double(target) }
        return start + (Double(target) - start) * max(0, elapsed) / duration
    }

    /// The whole number to draw at `time`.
    func figure(at time: TimeInterval) -> Int {
        Int(value(at: time).rounded(.down))
    }

    func hasArrived(at time: TimeInterval) -> Bool {
        value(at: time) >= Double(target)
    }

    /// Sets off for `count`, to arrive `duration` from `time`.
    mutating func aim(at count: Int, within duration: TimeInterval, at time: TimeInterval) {
        guard count != target || duration != self.duration else { return }
        let current = value(at: time)
        guard Double(count) >= current else {
            self = TokenClimb(at: count)
            return
        }
        start = current
        startTime = time
        target = count
        self.duration = duration
    }
}
