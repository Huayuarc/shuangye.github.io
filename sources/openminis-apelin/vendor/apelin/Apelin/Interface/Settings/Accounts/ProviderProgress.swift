import AlertController
import UIKit

/// FlowDown's progress alert. A cancel action exists only when it has work
/// to cancel, and dismissal finishes before another page is presented.
@MainActor
enum ProviderProgress {
    static func run<T>(
        title: String.LocalizationValue,
        message: String.LocalizationValue = "",
        from presenter: UIViewController,
        cancel: (@MainActor () async -> Void)? = nil,
        operation: @escaping @MainActor () async throws -> T,
    ) async throws -> T {
        if let cancel {
            return try await ProgressCard.run(
                title: String(localized: title),
                message: String(localized: message),
                cancellable: true,
                from: presenter,
            ) { _ in
                try await withTaskCancellationHandler {
                    try await operation()
                } onCancel: {
                    Task { @MainActor in await cancel() }
                }
            }
        }
        let indicator = AlertProgressIndicatorViewController(title: title, message: message)
        await withCheckedContinuation { continuation in
            presenter.present(indicator, animated: true) { continuation.resume() }
        }
        let task = Task { try await operation() }
        let result = await task.result
        await withCheckedContinuation { continuation in
            indicator.progressContext.dispose { continuation.resume() }
        }
        return try result.get()
    }
}
