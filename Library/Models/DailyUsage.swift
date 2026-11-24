import Foundation

/// One day's accumulated traffic, keyed by the local-calendar date the
/// bytes were observed on. `up` and `down` are bytes (cumulative within
/// the day), independent of the extension's session-scoped `upTotal` /
/// `downTotal` counters — this struct is the host-side aggregate that
/// survives extension restarts.
public struct DailyUsageEntry: Codable, Equatable, Identifiable, Sendable {
    /// `YYYY-MM-DD` in the user's current calendar at the time of
    /// observation. Stored as a string so JSON round-trips without
    /// timezone surprises.
    public let day: String
    public var up: Int64
    public var down: Int64

    public var id: String { day }
    public var total: Int64 { up &+ down }

    public init(day: String, up: Int64, down: Int64) {
        self.day = day
        self.up = up
        self.down = down
    }
}

/// On-disk shape of `daily_usage.json`. Holds both the rolling per-day
/// log and the most recent observed cumulative counters from the
/// extension. The latter lets the host compute deltas across launches
/// even when the extension keeps running between host process restarts.
public struct DailyUsageLog: Codable, Equatable, Sendable {
    /// Entries ordered oldest → newest. Truncated to the last
    /// `maxRetainedDays` on every persist.
    public var entries: [DailyUsageEntry]
    /// Most recent extension cumulative counters we persisted. `nil` on
    /// fresh install or after an explicit reset. Used to compute deltas
    /// against the next sample. Reset detection: when a new sample's
    /// totals are smaller, the extension restarted (counters reset to 0)
    /// and the new totals themselves are treated as the delta.
    public var lastObservedUpTotal: Int64?
    public var lastObservedDownTotal: Int64?

    public static let empty = DailyUsageLog(
        entries: [],
        lastObservedUpTotal: nil,
        lastObservedDownTotal: nil
    )

    public init(
        entries: [DailyUsageEntry],
        lastObservedUpTotal: Int64?,
        lastObservedDownTotal: Int64?
    ) {
        self.entries = entries
        self.lastObservedUpTotal = lastObservedUpTotal
        self.lastObservedDownTotal = lastObservedDownTotal
    }
}

/// Pure helpers that the store uses to fold a `TrafficSnapshot` stream
/// into a `DailyUsageLog`. Kept free of `@MainActor` and any persistence
/// concerns so they're trivial to unit-test (see `DailyUsageTests`).
public enum DailyUsage {
    /// How many days the rolling log keeps. The Statistics view shows
    /// the most recent slice; older entries are dropped on every persist.
    public static let maxRetainedDays = 30

    /// `YYYY-MM-DD` for `date` in `calendar`. Forced to a fixed POSIX
    /// locale so the persisted key never depends on the user's region
    /// (which would break sort order between installs / migrations).
    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        var cal = calendar
        cal.locale = Locale(identifier: "en_US_POSIX")
        let components = cal.dateComponents([.year, .month, .day], from: date)
        let y = components.year ?? 1970
        let m = components.month ?? 1
        let d = components.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Computes byte deltas from a new snapshot relative to the last
    /// persisted cumulative counters.
    ///
    /// * First sample (`previous == nil`): no delta — we're only seeding
    ///   the baseline. Skipping the very first reading loses at most one
    ///   second of bytes per fresh install; in exchange we never
    ///   double-count a session whose totals already reflect bytes the
    ///   user saw before they ever opened the host app.
    /// * Counter reset (any new total below the previous value): the
    ///   extension restarted, so the new totals themselves represent
    ///   bytes accumulated since the reset.
    /// * Otherwise: delta = new − previous.
    public static func delta(
        previousUp: Int64?,
        previousDown: Int64?,
        nextUp: Int64,
        nextDown: Int64
    ) -> (up: Int64, down: Int64) {
        guard let pUp = previousUp, let pDown = previousDown else {
            return (0, 0)
        }
        if nextUp < pUp || nextDown < pDown {
            return (max(0, nextUp), max(0, nextDown))
        }
        return (nextUp &- pUp, nextDown &- pDown)
    }

    /// Returns the subset of `entries` whose `day` falls within the
    /// `days`-long calendar window ending at `endingAt` (inclusive).
    /// Entries are filtered by their persisted day key against today's
    /// key minus `(days - 1)`, so e.g. a 7-day window ending Sunday
    /// includes Mon..Sun.
    ///
    /// Why filter by date instead of `suffix(days)`: with sparse usage
    /// (e.g. one entry from January and one from May), the count-based
    /// trim returns both rows; the chart correctly fills zero days
    /// inside the window, but the summary card would sum the January
    /// row too — visibly disagreeing with the chart.
    public static func entriesInWindow(
        _ entries: [DailyUsageEntry],
        days: Int,
        endingAt: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyUsageEntry] {
        guard days > 0 else { return [] }
        let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: endingAt) ?? endingAt
        let cutoffKey = dayKey(for: cutoff, calendar: calendar)
        let endKey = dayKey(for: endingAt, calendar: calendar)
        return entries.filter { $0.day >= cutoffKey && $0.day <= endKey }
    }

    /// Folds a positive delta into `entries`, creating today's entry if
    /// needed and dropping entries older than `maxRetainedDays`. Returns
    /// the updated array, ordered oldest → newest.
    public static func merge(
        entries: [DailyUsageEntry],
        addingDayKey day: String,
        up: Int64,
        down: Int64,
        retentionDays: Int = maxRetainedDays
    ) -> [DailyUsageEntry] {
        var merged = entries
        if let idx = merged.firstIndex(where: { $0.day == day }) {
            merged[idx].up &+= up
            merged[idx].down &+= down
        } else {
            merged.append(DailyUsageEntry(day: day, up: up, down: down))
        }
        merged.sort { $0.day < $1.day }
        if merged.count > retentionDays {
            merged.removeFirst(merged.count - retentionDays)
        }
        return merged
    }
}
