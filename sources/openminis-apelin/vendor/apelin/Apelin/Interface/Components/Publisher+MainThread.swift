// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import Combine
import Foundation

extension Publisher {
    /// Delivers each value on the main thread: at once when it is already
    /// there, otherwise on the main queue's next turn.
    func ensureMainThread() -> AnyPublisher<Output, Failure> {
        flatMap { value -> AnyPublisher<Output, Failure> in
            if Thread.isMainThread {
                Just(value)
                    .setFailureType(to: Failure.self)
                    .eraseToAnyPublisher()
            } else {
                Just(value)
                    .delay(for: .zero, scheduler: DispatchQueue.main)
                    .setFailureType(to: Failure.self)
                    .eraseToAnyPublisher()
            }
        }
        .eraseToAnyPublisher()
    }
}
