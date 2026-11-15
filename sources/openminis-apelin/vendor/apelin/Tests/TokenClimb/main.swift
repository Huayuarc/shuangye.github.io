import Foundation

func require(_ condition: Bool, _ message: String, line: Int = #line) {
    guard condition else { fatalError("Line \(line): \(message)") }
}

/// A count arrives five seconds after it came, straight from where the figure was.
var climb = TokenClimb(at: 0)
require(climb.figure(at: 0) == 0 && climb.hasArrived(at: 0), "At rest where it was put")
climb.aim(at: 1000, within: TokenClimb.running, at: 10)
require(climb.figure(at: 10) == 0, "It sets off from the figure")
require(climb.figure(at: 12.5) == 500, "Halfway there halfway through")
require(!climb.hasArrived(at: 14.9), "Not there before five seconds")
require(climb.figure(at: 15) == 1000 && climb.hasArrived(at: 15), "There at five seconds")
require(climb.figure(at: 99) == 1000, "It stays at the count")

// The same count and pace again keeps the time it was first asked for.
climb.aim(at: 1000, within: TokenClimb.running, at: 12.5)
require(climb.figure(at: 15) == 1000, "Asking again does not push the arrival back")

/// A higher count before arriving sets off from where the figure is: it never goes back.
var rising = TokenClimb(at: 0)
rising.aim(at: 1000, within: TokenClimb.running, at: 0)
rising.aim(at: 2000, within: TokenClimb.running, at: 2.5)
require(rising.figure(at: 2.5) == 500, "A new count starts from the figure, not the old count")
require(rising.figure(at: 7.5) == 2000, "And arrives five seconds after it came")
var last = 0
for step in 0 ... 100 {
    let figure = rising.figure(at: 2.5 + Double(step) * 0.05)
    require(figure >= last, "The figure only climbs")
    last = figure
}

/// The reply has begun: what is left arrives in half a second.
var settling = TokenClimb(at: 0)
settling.aim(at: 800, within: TokenClimb.running, at: 0)
settling.aim(at: 800, within: TokenClimb.settling, at: 1)
require(settling.figure(at: 1) == 160, "Settling starts from the figure")
require(settling.figure(at: 1.5) == 800 && settling.hasArrived(at: 1.5), "And arrives half a second later")
settling.aim(at: 900, within: TokenClimb.settling, at: 2)
require(settling.figure(at: 2.25) == 850 && settling.figure(at: 2.5) == 900, "Counts while settling take half a second")

/// A lower count is shown at once.
var lower = TokenClimb(at: 0)
lower.aim(at: 500, within: TokenClimb.running, at: 0)
lower.aim(at: 50, within: TokenClimb.running, at: 1)
require(lower.figure(at: 1) == 50 && lower.hasArrived(at: 1), "A lower count does not climb down")

print("ok: TokenClimb")
