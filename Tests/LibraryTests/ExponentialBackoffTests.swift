import XCTest
@testable import Library

final class ExponentialBackoffTests: XCTestCase {
    func testStartsAtInitial() {
        let b = ExponentialBackoff(initialMs: 200, maxMs: 5_000)
        XCTAssertEqual(b.currentDelayMs, 200)
    }

    func testDoublesAndCaps() async {
        var b = ExponentialBackoff(initialMs: 1, maxMs: 4)
        await b.sleep()
        XCTAssertEqual(b.currentDelayMs, 2)
        await b.sleep()
        XCTAssertEqual(b.currentDelayMs, 4)
        // Capped — no further growth.
        await b.sleep()
        XCTAssertEqual(b.currentDelayMs, 4)
    }

    func testResetReturnsToInitial() async {
        var b = ExponentialBackoff(initialMs: 1, maxMs: 4)
        await b.sleep()
        await b.sleep()
        XCTAssertEqual(b.currentDelayMs, 4)
        b.reset()
        XCTAssertEqual(b.currentDelayMs, 1)
    }

    /// Cancellation must not throw out of `sleep()` — calling loops use
    /// `Task.isCancelled` for the exit signal.
    func testSleepSwallowsCancellation() async {
        let task = Task {
            var b = ExponentialBackoff(initialMs: 100_000, maxMs: 100_000)
            await b.sleep()
        }
        task.cancel()
        await task.value  // would throw if sleep() didn't swallow CancellationError
    }

    func testRetryLoopRunsBodyUntilCancelled() async {
        let attempts = Box<Int>(value: 0)
        let task = Task {
            await RetryLoop.run(
                backoff: ExponentialBackoff(initialMs: 1, maxMs: 4)
            ) {
                _ = await attempts.increment()
                return false
            }
        }
        // 50 ms is plenty for the 1-2-4-4 ms cadence to make ≥3 attempts.
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await task.value
        let total = await attempts.value
        XCTAssertGreaterThan(total, 1, "RetryLoop must run body more than once before cancellation")
    }

    func testRetryLoopExitsImmediatelyWhenCancelled() async {
        // Body runs at most once (or zero times if the cancellation
        // beats the first iteration); the loop must not deadlock.
        let task = Task {
            await RetryLoop.run(
                backoff: ExponentialBackoff(initialMs: 1, maxMs: 1)
            ) {
                return true   // success: backoff reset; loop exits next iter
            }
        }
        task.cancel()
        // Should not hang — the cancellation is observed at the top of
        // the next loop pass after the body returns true.
        await task.value
    }
}

/// Tiny actor box for sharing mutable state across an async closure
/// without forming a Sendable headache.
private actor Box<T: Sendable> {
    private(set) var value: T
    init(value: T) { self.value = value }
    func set(_ v: T) { value = v }
}

extension Box where T == Int {
    func increment() -> Int {
        value += 1
        return value
    }
}
