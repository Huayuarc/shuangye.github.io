import ApelinConsole
import ApelinCore
import ApelinProtocol
import UIKit

extension ConsoleRunner {
    /// The app's console: apelind through `DaemonClient`, mobile's data
    /// folder, the unified log. The runner itself is ApelinConsole's, tested
    /// on the Mac by `make harness`.
    static let shared = ConsoleRunner(service: .app, folder: .app, log: UnifiedLogSink())
}

/// Starts the console from `didFinishLaunching`: the launch argument's
/// script, what an earlier launch left running, and the inbox now; the inbox
/// again on every return to the foreground. The console never touches the
/// UI and never quits the app.
///
/// While a script runs the screen does not lock by itself: a locked device
/// suspends the app, and a `wait` or a followed task stalls with it (seen on
/// the iOS 26.4 vphone, 2026-10-17).
enum ConsoleLaunch {
    /// Scripts being run now; the idle timer is off while there are any.
    @MainActor private static var running = 0

    static func start() {
        let arguments = CommandLine.arguments
        Task.detached(priority: .utility) {
            await keepingAwake { await ConsoleRunner.shared.runLaunchScript(arguments: arguments) }
        }
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main,
        ) { _ in
            Task.detached(priority: .utility) {
                await keepingAwake { await ConsoleRunner.shared.drainInbox() }
            }
        }
    }

    private static func keepingAwake(_ body: () async -> Void) async {
        await MainActor.run {
            running += 1
            UIApplication.shared.isIdleTimerDisabled = true
        }
        await body()
        await MainActor.run {
            running -= 1
            if running == 0 {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}
