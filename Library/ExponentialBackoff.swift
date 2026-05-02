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
///
/// For the common "loop forever, reset on success" shape, prefer
/// `RetryLoop.run(_:)` which encapsulates the cancellation check and
/// the reset/sleep dance.
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

    /// Visible for tests: the current delay before sleep() advances it.
    public var currentDelayMs: UInt64 { currentMs }
}

/// "Retry an async block until cancelled, with exponential backoff between
/// attempts that succeed → reset, fail → sleep." Same shape ConnectionsStore
/// and CommandClient both used to implement inline. Pulling it out:
///
///   1. Means there is one place to fix backoff bugs.
///   2. Lets tests exercise the loop without spinning a real network.
///   3. Documents the contract: the body returns true to mean "made
///      progress, reset the backoff" and false to mean "transient error,
///      sleep before retrying."
public enum RetryLoop {
    /// Drives `body` in a loop until the surrounding task is cancelled.
    /// Returns true after a successful attempt, false to keep backing off.
    /// The body receives the current backoff delay (ms) for telemetry.
    public static func run(
        backoff: ExponentialBackoff = ExponentialBackoff(),
        body: @Sendable () async -> Bool
    ) async {
        var b = backoff
        while !Task.isCancelled {
            let ok = await body()
            if Task.isCancelled { break }
            if ok { b.reset() }
            await b.sleep()
        }
    }
}
