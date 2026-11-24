import Foundation
import Library
import SwiftUI

/// Window selector for the Statistics screen.
enum StatisticsRange: Int, CaseIterable, Identifiable {
    case week = 7
    case twoWeeks = 14
    case month = 30

    var id: Int { rawValue }
    var dayCount: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .week: return "7 days"
        case .twoWeeks: return "14 days"
        case .month: return "30 days"
        }
    }

    /// How many days between successive x-axis ticks. Sized so the
    /// label count stays in the 6–8 range across all picker settings,
    /// leaving enough horizontal room that even the widest "M/d" label
    /// can't collide on a 360pt-wide chart.
    var xAxisStrideDays: Int {
        switch self {
        case .week: return 1     // 7 labels: Mon, Tue, …
        case .twoWeeks: return 2 // 7 labels at 2-day spacing
        case .month: return 5    // 6 labels at 5-day spacing
        }
    }

    /// Date label format paired with `xAxisStrideDays`. 7-day mode
    /// uses weekday names since the user's mental model is "this
    /// past week"; the longer ranges drop to numeric M/d so the
    /// labels stay narrow enough at the chosen stride.
    var xAxisFormat: Date.FormatStyle {
        switch self {
        case .week:
            return Date.FormatStyle().weekday(.abbreviated)
        case .twoWeeks, .month:
            return Date.FormatStyle().month(.defaultDigits).day(.defaultDigits)
        }
    }
}

enum ChartDirection {
    case up, down

    var localizedTitle: String {
        switch self {
        case .up: return String(localized: "Upload", bundle: .main)
        case .down: return String(localized: "Download", bundle: .main)
        }
    }
}

struct ChartPoint: Identifiable {
    let id: String
    let date: Date
    let bytes: Int64
    let direction: ChartDirection
}

struct UsageModel {
    let recent: [DailyUsageEntry]
    let series: [ChartPoint]
    let totalUp: Int64
    let totalDown: Int64

    var total: Int64 { totalUp &+ totalDown }
}

/// Pure shaping of the persisted daily log into the windowed model the
/// Statistics screen renders. Kept out of the view so the summary and
/// the chart share exactly one windowing rule (and can be unit-tested).
enum StatisticsUsage {
    static func model(
        entries: [DailyUsageEntry],
        range: StatisticsRange,
        endingAt: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageModel {
        let windowed = DailyUsage.entriesInWindow(
            entries,
            days: range.dayCount,
            endingAt: endingAt,
            calendar: calendar
        )
        let totalUp = windowed.reduce(into: Int64(0)) { $0 &+= $1.up }
        let totalDown = windowed.reduce(into: Int64(0)) { $0 &+= $1.down }
        return UsageModel(
            recent: Array(windowed.reversed()),
            series: series(entries: entries, range: range, endingAt: endingAt, calendar: calendar),
            totalUp: totalUp,
            totalDown: totalDown
        )
    }

    /// Builds chart points covering exactly `range.dayCount` days,
    /// ending at `endingAt`. Days with no recorded traffic show as zero
    /// bars rather than gaps so the x-axis stays evenly spaced.
    static func series(
        entries: [DailyUsageEntry],
        range: StatisticsRange,
        endingAt: Date = Date(),
        calendar: Calendar = .current
    ) -> [ChartPoint] {
        let window = range.dayCount
        let startOfToday = calendar.startOfDay(for: endingAt)
        // Build the lookup defensively instead of `uniqueKeysWithValues`:
        // a hand-edited / restored daily log could contain duplicate day
        // keys, and a trap in a chart body is not an acceptable failure.
        var lookup: [String: DailyUsageEntry] = [:]
        lookup.reserveCapacity(entries.count)
        for entry in entries {
            lookup[entry.day] = entry
        }
        var points: [ChartPoint] = []
        points.reserveCapacity(window * 2)

        for offset in stride(from: window - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else {
                continue
            }
            let key = DailyUsage.dayKey(for: date, calendar: calendar)
            let entry = lookup[key]
            points.append(ChartPoint(id: "\(key)-up", date: date, bytes: entry?.up ?? 0, direction: .up))
            points.append(ChartPoint(id: "\(key)-down", date: date, bytes: entry?.down ?? 0, direction: .down))
        }
        return points
    }
}
