import Foundation
import Observation

/// Wraps `withObservationTracking` in an `AsyncStream` so observation
/// of `@Observable` properties can be consumed with `for await`. Emits
/// the initial value, then a fresh value every time the read closure's
/// tracked properties change. Stream terminates (and the producer Task
/// cancels) when the consumer breaks out of its loop or its enclosing
/// Task is cancelled.
public enum Observed {
    public static func values<T: Sendable>(
        _ read: @escaping @Sendable @MainActor () -> T
    ) -> AsyncStream<T> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                while !Task.isCancelled {
                    let value = withObservationTracking({ read() }, onChange: {})
                    continuation.yield(value)
                    await withCheckedContinuation { (cc: CheckedContinuation<Void, Never>) in
                        withObservationTracking({ _ = read() }, onChange: { cc.resume() })
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
