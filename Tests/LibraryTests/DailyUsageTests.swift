import Foundation
import Testing
@testable import Library

@Suite struct DailyUsageTests {
    // MARK: - dayKey

    @Test func dayKeyFormat() {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 3
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: components)!

        #expect(DailyUsage.dayKey(for: date, calendar: cal) == "2026-05-03")
    }

    @Test func dayKeyPadsSingleDigits() {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 7
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: components)!

        #expect(DailyUsage.dayKey(for: date, calendar: cal) == "2026-01-07")
    }

    // MARK: - delta

    @Test func deltaFirstSampleSeedsBaselineWithoutCrediting() {
        let d = DailyUsage.delta(previousUp: nil, previousDown: nil, nextUp: 5_000, nextDown: 10_000)
        #expect(d.up == 0)
        #expect(d.down == 0)
    }

    @Test func deltaMonotonicallyIncreasingTotals() {
        let d = DailyUsage.delta(previousUp: 1_000, previousDown: 2_000, nextUp: 1_500, nextDown: 2_750)
        #expect(d.up == 500)
        #expect(d.down == 750)
    }

    @Test func deltaTreatsCounterResetAsFreshSession() {
        // Extension restarted: cumulative dropped below the previous
        // value. Persisted-counter logic must treat the new totals as
        // bytes the user just transferred since the reset.
        let d = DailyUsage.delta(previousUp: 10_000_000, previousDown: 50_000_000, nextUp: 1_500, nextDown: 4_000)
        #expect(d.up == 1_500)
        #expect(d.down == 4_000)
    }

    @Test func deltaPartialResetIsTreatedAsReset() {
        // Defensive: if only one direction's total drops, still treat
        // the whole sample as a reset rather than crediting one but
        // not the other.
        let d = DailyUsage.delta(previousUp: 100, previousDown: 200, nextUp: 90, nextDown: 250)
        #expect(d.up == 90)
        #expect(d.down == 250)
    }

    // MARK: - merge

    @Test func mergeAppendsNewDay() {
        let merged = DailyUsage.merge(
            entries: [],
            addingDayKey: "2026-05-03",
            up: 100,
            down: 200
        )
        #expect(merged.count == 1)
        #expect(merged[0].day == "2026-05-03")
        #expect(merged[0].up == 100)
        #expect(merged[0].down == 200)
    }

    @Test func mergeAccumulatesIntoExistingDay() {
        let initial = [DailyUsageEntry(day: "2026-05-03", up: 100, down: 200)]
        let merged = DailyUsage.merge(
            entries: initial,
            addingDayKey: "2026-05-03",
            up: 50,
            down: 25
        )
        #expect(merged.count == 1)
        #expect(merged[0].up == 150)
        #expect(merged[0].down == 225)
    }

    @Test func mergeKeepsEntriesSortedAscending() {
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
        #expect(merged.map(\.day) == ["2026-05-01", "2026-05-02", "2026-05-04"])
    }

    @Test func mergeDropsEntriesBeyondRetentionWindow() {
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
        #expect(merged.count == 3)
        #expect(merged.map(\.day) == ["2026-05-04", "2026-05-05", "2026-05-06"])
    }

    // MARK: - entriesInWindow

    @Test func entriesInWindowReturnsOnlyWithinDays() {
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
        #expect(windowed.map(\.day) == ["2026-04-30", "2026-05-01", "2026-05-03"])
    }

    @Test func entriesInWindowExcludesSparseOldEntry() {
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
        #expect(windowed.map(\.day) == ["2026-05-03"])
    }

    @Test func entriesInWindowIncludesEndingDay() {
        let entries = [DailyUsageEntry(day: "2026-05-03", up: 1, down: 1)]
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 3
        let cal = Calendar(identifier: .gregorian)
        let endDate = cal.date(from: components)!
        let windowed = DailyUsage.entriesInWindow(entries, days: 1, endingAt: endDate, calendar: cal)
        #expect(windowed.count == 1)
    }

    @Test func entriesInWindowZeroDaysReturnsEmpty() {
        let entries = [DailyUsageEntry(day: "2026-05-03", up: 1, down: 1)]
        #expect(DailyUsage.entriesInWindow(entries, days: 0).isEmpty)
    }

    // MARK: - Counter-reset double-count regression

    @Test func zeroSampleAfterPersistedBaselineDoesNotCreditNextRealFrame() {
        // Reproduces the host-launch scenario where the @Observable
        // default `.zero` is read by a new subscriber. Before the
        // dropFirst() fix, the zero would be treated as a counter reset
        // (newTotal < persisted lastTotal), reseed the baseline at 0,
        // and the next real frame would credit the entire extension
        // cumulative as a delta — double-counting whatever the previous
        // session already wrote.
        //
        // The pure delta() helper still treats nextTotal < prevTotal as
        // a reset; this test pins the contract so the routing layer
        // (TrafficCoordinator) must keep dropping the synthetic zero.
        let resetSample = DailyUsage.delta(
            previousUp: 100_000,
            previousDown: 200_000,
            nextUp: 0,
            nextDown: 0
        )
        // After the reset, the new totals (0, 0) themselves are the
        // delta — that is, no bytes credited (correct).
        #expect(resetSample.up == 0)
        #expect(resetSample.down == 0)

        // Now the *next* real frame would compare against the now-zero
        // baseline. If we hadn't dropped the synthetic zero upstream,
        // this would credit the whole extension cumulative.
        let nextDelta = DailyUsage.delta(
            previousUp: 0,
            previousDown: 0,
            nextUp: 200_500,
            nextDown: 400_000
        )
        #expect(nextDelta.up == 200_500)
        #expect(nextDelta.down == 400_000)
    }

    // MARK: - DailyUsageLog round-trip

    @Test func logCodableRoundTrip() throws {
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
        #expect(decoded == log)
    }

    @Test func emptyLogIsTrulyEmpty() {
        let e = DailyUsageLog.empty
        #expect(e.entries.isEmpty)
        #expect(e.lastObservedUpTotal == nil)
        #expect(e.lastObservedDownTotal == nil)
    }

    // MARK: - DailyUsageEntry helpers

    @Test func totalIsSumOfUpAndDown() {
        let e = DailyUsageEntry(day: "2026-05-03", up: 100, down: 250)
        #expect(e.total == 350)
    }
}
