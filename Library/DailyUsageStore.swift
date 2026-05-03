import Combine
import Foundation
import os

/// Aggregates the extension's traffic stream into a per-day log that
/// survives across host launches and extension restarts.
///
/// Wiring: `ExtensionEnvironment` subscribes the running `CommandClient`
/// to this store via `record(snapshot:at:)` on every Status frame. The
/// store keeps the most recent extension cumulative totals it has seen
/// so the next sample yields a delta the way the dashboard's session
/// totals do — with a small wrinkle for counter resets (see
/// `DailyUsage.delta`).
///
/// Persistence is throttled rather than synchronous: traffic samples
/// arrive at 1 Hz while connected, but the user looks at the chart
/// once per session at most, and writing a tiny JSON 60 times a minute
/// is gratuitous battery + flash wear. We coalesce dirty in-memory
/// state and flush every `persistInterval` seconds (and on demand from
/// the resign-active hook).
@MainActor
public final class DailyUsageStore: ObservableObject {
    public static let shared = DailyUsageStore()

    private static let logger = Logger(subsystem: "io.proxycat.Library", category: "DailyUsageStore")

    /// Most-recent-last. Caps at `DailyUsage.maxRetainedDays` (30).
    @Published public private(set) var entries: [DailyUsageEntry]

    private var lastObservedUpTotal: Int64?
    private var lastObservedDownTotal: Int64?

    /// Set by `record(...)` and cleared by `flush()`. Avoids round-tripping
    /// to disk when nothing changed since the last flush.
    private var dirty: Bool = false

    /// How long we wait between disk writes when traffic is flowing.
    /// Picked to be long enough to amortize many 1 Hz samples but short
    /// enough that a crash mid-session doesn't lose visible data.
    private let persistInterval: TimeInterval = 5

    private var flushTask: Task<Void, Never>?

    private init() {
        let stored = JSONFileStore.load(
            DailyUsageLog.self,
            at: FilePath.dailyUsageFilePath,
            default: .empty
        )
        self.entries = stored.entries
        self.lastObservedUpTotal = stored.lastObservedUpTotal
        self.lastObservedDownTotal = stored.lastObservedDownTotal
    }

    /// Test-only initializer that loads from a custom path.
    init(loadingFrom path: String) {
        let stored = JSONFileStore.load(DailyUsageLog.self, at: path, default: .empty)
        self.entries = stored.entries
        self.lastObservedUpTotal = stored.lastObservedUpTotal
        self.lastObservedDownTotal = stored.lastObservedDownTotal
    }

    deinit {
        flushTask?.cancel()
    }

    /// Folds one extension status frame into the daily log.
    ///
    /// The first sample after launch (or after `reset()`) only seeds the
    /// baseline; no bytes are credited to any day. Subsequent samples
    /// add `(newTotal − lastTotal)` to today's entry, treating any
    /// reduction as an extension counter reset (see
    /// `DailyUsage.delta`).
    public func record(snapshot: TrafficSnapshot, at date: Date = Date(), calendar: Calendar = .current) {
        let (upDelta, downDelta) = DailyUsage.delta(
            previousUp: lastObservedUpTotal,
            previousDown: lastObservedDownTotal,
            nextUp: snapshot.upTotal,
            nextDown: snapshot.downTotal
        )

        lastObservedUpTotal = snapshot.upTotal
        lastObservedDownTotal = snapshot.downTotal

        if upDelta == 0, downDelta == 0 {
            // Even when no bytes were credited, the baseline may have
            // moved (e.g. first sample after launch); persist on the
            // next flush window so we don't reseed the same baseline
            // repeatedly across cold launches.
            dirty = true
            scheduleFlush()
            return
        }

        let day = DailyUsage.dayKey(for: date, calendar: calendar)
        entries = DailyUsage.merge(
            entries: entries,
            addingDayKey: day,
            up: upDelta,
            down: downDelta
        )
        dirty = true
        scheduleFlush()
    }

    /// Drops the on-disk + in-memory log and forgets the cumulative
    /// baseline so the next sample seeds a fresh one. Used by the
    /// "Reset statistics" action in the UI.
    public func reset() {
        entries = []
        lastObservedUpTotal = nil
        lastObservedDownTotal = nil
        dirty = false
        flushTask?.cancel()
        flushTask = nil
        let snapshot = DailyUsageLog(entries: [], lastObservedUpTotal: nil, lastObservedDownTotal: nil)
        JSONFileStore.saveOrLog(
            snapshot,
            to: FilePath.dailyUsageFilePath,
            category: "DailyUsageStore"
        )
    }

    /// Force-flush any pending state to disk. Called from the host app
    /// on willResignActive so a backgrounded session keeps its last
    /// few seconds of traffic on the next launch.
    public func flushNow() {
        guard dirty else { return }
        flushTask?.cancel()
        flushTask = nil
        persist()
    }

    /// Total bytes (up + down) over the entire retained window. Used by
    /// the chart header.
    public var totalBytes: Int64 {
        entries.reduce(into: Int64(0)) { acc, entry in
            acc &+= entry.total
        }
    }

    public var totalUp: Int64 {
        entries.reduce(into: Int64(0)) { acc, entry in acc &+= entry.up }
    }

    public var totalDown: Int64 {
        entries.reduce(into: Int64(0)) { acc, entry in acc &+= entry.down }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let delay = persistInterval
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            self.flushTask = nil
            if self.dirty {
                self.persist()
            }
        }
    }

    private func persist() {
        let snapshot = DailyUsageLog(
            entries: entries,
            lastObservedUpTotal: lastObservedUpTotal,
            lastObservedDownTotal: lastObservedDownTotal
        )
        if JSONFileStore.saveOrLog(
            snapshot,
            to: FilePath.dailyUsageFilePath,
            category: "DailyUsageStore"
        ) {
            dirty = false
        }
    }
}
