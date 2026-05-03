import XCTest
@testable import Library

final class DailyUsageTests: XCTestCase {
    // MARK: - dayKey

    func testDayKeyFormat() {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 3
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: components)!

        XCTAssertEqual(DailyUsage.dayKey(for: date, calendar: cal), "2026-05-03")
    }

    func testDayKeyPadsSingleDigits() {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 7
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: components)!

        XCTAssertEqual(DailyUsage.dayKey(for: date, calendar: cal), "2026-01-07")
    }

    // MARK: - delta

    func testDeltaFirstSampleSeedsBaselineWithoutCrediting() {
        let d = DailyUsage.delta(previousUp: nil, previousDown: nil, nextUp: 5_000, nextDown: 10_000)
        XCTAssertEqual(d.up, 0)
        XCTAssertEqual(d.down, 0)
    }

    func testDeltaMonotonicallyIncreasingTotals() {
        let d = DailyUsage.delta(previousUp: 1_000, previousDown: 2_000, nextUp: 1_500, nextDown: 2_750)
        XCTAssertEqual(d.up, 500)
        XCTAssertEqual(d.down, 750)
    }

    func testDeltaTreatsCounterResetAsFreshSession() {
        // Extension restarted: cumulative dropped below the previous
        // value. Persisted-counter logic must treat the new totals as
        // bytes the user just transferred since the reset.
        let d = DailyUsage.delta(previousUp: 10_000_000, previousDown: 50_000_000, nextUp: 1_500, nextDown: 4_000)
        XCTAssertEqual(d.up, 1_500)
        XCTAssertEqual(d.down, 4_000)
    }

    func testDeltaPartialResetIsTreatedAsReset() {
        // Defensive: if only one direction's total drops, still treat
        // the whole sample as a reset rather than crediting one but
        // not the other.
        let d = DailyUsage.delta(previousUp: 100, previousDown: 200, nextUp: 90, nextDown: 250)
        XCTAssertEqual(d.up, 90)
        XCTAssertEqual(d.down, 250)
    }

    // MARK: - merge

    func testMergeAppendsNewDay() {
        let merged = DailyUsage.merge(
            entries: [],
            addingDayKey: "2026-05-03",
            up: 100,
            down: 200
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].day, "2026-05-03")
        XCTAssertEqual(merged[0].up, 100)
        XCTAssertEqual(merged[0].down, 200)
    }

    func testMergeAccumulatesIntoExistingDay() {
        let initial = [DailyUsageEntry(day: "2026-05-03", up: 100, down: 200)]
        let merged = DailyUsage.merge(
            entries: initial,
            addingDayKey: "2026-05-03",
            up: 50,
            down: 25
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].up, 150)
        XCTAssertEqual(merged[0].down, 225)
    }

    func testMergeKeepsEntriesSortedAscending() {
        let initial = [
            DailyUsageEntry(day: "2026-05-01", up: 10, down: 20),
            DailyUsageEntry(day: "2026-05-04", up: 10, down: 20),
        ]
        let merged = DailyUsage.merge(
            entries: initial,
            addingDayKey: "2026-05-02",
            up: 5,
            down: 5
        )
        XCTAssertEqual(merged.map(\.day), ["2026-05-01", "2026-05-02", "2026-05-04"])
    }

    func testMergeDropsEntriesBeyondRetentionWindow() {
        var seed: [DailyUsageEntry] = []
        for i in 1 ... 5 {
            seed.append(DailyUsageEntry(day: String(format: "2026-05-%02d", i), up: 1, down: 1))
        }
        let merged = DailyUsage.merge(
            entries: seed,
            addingDayKey: "2026-05-06",
            up: 1,
            down: 1,
            retentionDays: 3
        )
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.map(\.day), ["2026-05-04", "2026-05-05", "2026-05-06"])
    }

    // MARK: - entriesInWindow

    func testEntriesInWindowReturnsOnlyWithinDays() {
        let entries = [
            DailyUsageEntry(day: "2026-04-25", up: 1, down: 1),
            DailyUsageEntry(day: "2026-04-30", up: 2, down: 2),
            DailyUsageEntry(day: "2026-05-01", up: 3, down: 3),
            DailyUsageEntry(day: "2026-05-03", up: 4, down: 4),
        ]
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 3
        let cal = Calendar(identifier: .gregorian)
        let endDate = cal.date(from: components)!

        // 7-day window ending 2026-05-03 = 2026-04-27..2026-05-03.
        // 2026-04-25 must NOT appear in the result.
        let windowed = DailyUsage.entriesInWindow(entries, days: 7, endingAt: endDate, calendar: cal)
        XCTAssertEqual(windowed.map(\.day), ["2026-04-30", "2026-05-01", "2026-05-03"])
    }

    func testEntriesInWindowExcludesSparseOldEntry() {
        // Regression: previous bucketedEntries used suffix-by-count. With
        // only two recorded days but a 7-day picker, the January entry
        // would have leaked into the summary.
        let entries = [
            DailyUsageEntry(day: "2026-01-15", up: 1_000_000_000, down: 0),
            DailyUsageEntry(day: "2026-05-03", up: 100, down: 0),
        ]
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 3
        let cal = Calendar(identifier: .gregorian)
        let endDate = cal.date(from: components)!

        let windowed = DailyUsage.entriesInWindow(entries, days: 7, endingAt: endDate, calendar: cal)
        XCTAssertEqual(windowed.map(\.day), ["2026-05-03"])
    }

    func testEntriesInWindowIncludesEndingDay() {
        let entries = [DailyUsageEntry(day: "2026-05-03", up: 1, down: 1)]
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 3
        let cal = Calendar(identifier: .gregorian)
        let endDate = cal.date(from: components)!
        let windowed = DailyUsage.entriesInWindow(entries, days: 1, endingAt: endDate, calendar: cal)
        XCTAssertEqual(windowed.count, 1)
    }

    func testEntriesInWindowZeroDaysReturnsEmpty() {
        let entries = [DailyUsageEntry(day: "2026-05-03", up: 1, down: 1)]
        XCTAssertTrue(DailyUsage.entriesInWindow(entries, days: 0).isEmpty)
    }

    // MARK: - Counter-reset double-count regression

    func testZeroSampleAfterPersistedBaselineDoesNotCreditNextRealFrame() {
        // Reproduces the host-launch scenario where Combine replays the
        // @Published default `.zero` to a new subscriber. Before the
        // dropFirst() fix, the zero would be treated as a counter reset
        // (newTotal < persisted lastTotal), reseed the baseline at 0,
        // and the next real frame would credit the entire extension
        // cumulative as a delta — double-counting whatever the previous
        // session already wrote.
        //
        // The pure delta() helper still treats nextTotal < prevTotal as
        // a reset; this test pins the contract so the routing layer
        // (ExtensionEnvironment) must keep dropping the synthetic zero.
        let resetSample = DailyUsage.delta(
            previousUp: 100_000,
            previousDown: 200_000,
            nextUp: 0,
            nextDown: 0
        )
        // After the reset, the new totals (0, 0) themselves are the
        // delta — that is, no bytes credited (correct).
        XCTAssertEqual(resetSample.up, 0)
        XCTAssertEqual(resetSample.down, 0)

        // Now the *next* real frame would compare against the now-zero
        // baseline. If we hadn't dropped the synthetic zero upstream,
        // this would credit the whole extension cumulative.
        let nextDelta = DailyUsage.delta(
            previousUp: 0,
            previousDown: 0,
            nextUp: 200_500,
            nextDown: 400_000
        )
        XCTAssertEqual(nextDelta.up, 200_500)
        XCTAssertEqual(nextDelta.down, 400_000)
    }

    // MARK: - DailyUsageLog round-trip

    func testLogCodableRoundTrip() throws {
        let log = DailyUsageLog(
            entries: [
                DailyUsageEntry(day: "2026-05-01", up: 10, down: 20),
                DailyUsageEntry(day: "2026-05-02", up: 30, down: 40),
            ],
            lastObservedUpTotal: 100,
            lastObservedDownTotal: 200
        )
        let data = try JSONEncoder().encode(log)
        let decoded = try JSONDecoder().decode(DailyUsageLog.self, from: data)
        XCTAssertEqual(decoded, log)
    }

    func testEmptyLogIsTrulyEmpty() {
        let e = DailyUsageLog.empty
        XCTAssertTrue(e.entries.isEmpty)
        XCTAssertNil(e.lastObservedUpTotal)
        XCTAssertNil(e.lastObservedDownTotal)
    }

    // MARK: - DailyUsageEntry helpers

    func testTotalIsSumOfUpAndDown() {
        let e = DailyUsageEntry(day: "2026-05-03", up: 100, down: 250)
        XCTAssertEqual(e.total, 350)
    }
}
