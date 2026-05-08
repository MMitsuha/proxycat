import Foundation
import Observation

/// Wraps `withObservationTracking` in an `AsyncStream` so observation
/// of `@Observable` properties can be consumed with `for await`.
///
/// The wait between yields uses an inner `AsyncStream<Void>` instead of
/// a non-throwing `withCheckedContinuation` — the latter is not
/// cancellation-aware, so a consumer that broke out of its for-loop
/// would leak both the producer Task and the continuation forever.
public enum Observed {
    public static func values<T: Sendable>(
        _ read: @escaping @Sendable @MainActor () -> T
    ) -> AsyncStream<T> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                while !Task.isCancelled {
                    let (changeStream, changeContinuation) = AsyncStream<Void>.makeStream(
                        bufferingPolicy: .bufferingNewest(1)
                    )
                    let value = withObservationTracking({ read() }) {
                        changeContinuation.yield(())
                        changeContinuation.finish()
                    }
                    continuation.yield(value)
                    // AsyncStream iteration propagates cancellation: when
                    // our enclosing Task is cancelled, next() returns nil
                    // and the for-await exits without breaking, so the
                    // outer while sees Task.isCancelled and finishes.
                    for await _ in changeStream { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
