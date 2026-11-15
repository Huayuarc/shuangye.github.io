import UIKit

/// Log viewer lines by level, Irisin's: a verbose line is dimmed; a
/// warning, an error and a critical line are red, the last two on a red
/// wash.
extension UIColor {
    static let logVerbose = UIColor.systemGray
    static let logVerboseDetail = UIColor.systemGray2
    static let logProblem = UIColor.systemRed
    static let logProblemDetail = UIColor.systemRed.withAlphaComponent(0.7)
    static let logErrorBackground = UIColor.systemRed.withAlphaComponent(0.05)
    static let logCriticalBackground = UIColor.systemRed.withAlphaComponent(0.12)
}
