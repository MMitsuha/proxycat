import Foundation

/// Capped doubling backoff for retry loops. Mutating value type so each
/// retry loop owns its own progression without sharing state.
///
/// Typical usage in an async retry loop:
///
///     var backoff = ExponentialBackoff()
///     while !Task.isCancelled {
///         let ok = await attempt()
///         if Task.isCancelled { break }
///         if ok { backoff.reset() }
///         await backoff.sleep()
///     }
public struct ExponentialBackoff: Sendable {
    private let initialMs: UInt64
    private let maxMs: UInt64
    private var currentMs: UInt64

    public init(initialMs: UInt64 = 200, maxMs: UInt64 = 5_000) {
        precondition(initialMs > 0 && maxMs >= initialMs)
        self.initialMs = initialMs
        self.maxMs = maxMs
        self.currentMs = initialMs
    }

    public mutating func reset() {
        currentMs = initialMs
    }

    /// Sleeps for the current delay, then doubles it (capped at `maxMs`).
    /// Cancellation propagates as a no-op — `Task.sleep` throws which we
    /// swallow, but the calling loop's `Task.isCancelled` check will see
    /// the cancellation on the next iteration.
    public mutating func sleep() async {
        try? await Task.sleep(nanoseconds: currentMs * NSEC_PER_MSEC)
        currentMs = Swift.min(currentMs * 2, maxMs)
    }
}
