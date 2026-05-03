import Charts
import Library
import SwiftUI

public struct StatisticsView: View {
    @EnvironmentObject private var dailyUsage: DailyUsageStore

    @State private var range: Range = .week
    @State private var showResetConfirm = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                rangePicker
                summaryCard
                chartCard
                listCard
                resetButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Reset statistics?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { dailyUsage.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Drops the locally stored daily totals. Live traffic counters on the dashboard are unaffected.")
        }
    }

    // MARK: - Sections

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(Range.allCases) { r in
                Text(r.title).tag(r)
            }
        }
        .pickerStyle(.segmented)
    }

    private var summaryCard: some View {
        let bucketed = bucketedEntries()
        let totalUp = bucketed.reduce(into: Int64(0)) { $0 &+= $1.up }
        let totalDown = bucketed.reduce(into: Int64(0)) { $0 &+= $1.down }
        let total = totalUp &+ totalDown

        return HStack(alignment: .top, spacing: 12) {
            summaryColumn(
                title: "Total",
                value: ByteFormatter.string(total),
                color: .accentColor,
                symbol: "sum"
            )
            Divider().frame(height: 36)
            summaryColumn(
                title: "Upload",
                value: ByteFormatter.string(totalUp),
                color: .blue,
                symbol: "arrow.up.circle.fill"
            )
            Divider().frame(height: 36)
            summaryColumn(
                title: "Download",
                value: ByteFormatter.string(totalDown),
                color: .green,
                symbol: "arrow.down.circle.fill"
            )
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private func summaryColumn(title: LocalizedStringKey, value: String, color: Color, symbol: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily traffic")
                .font(.subheadline.weight(.semibold))
            chartContent
                .frame(height: 180)
        }
        .card()
    }

    @ViewBuilder
    private var chartContent: some View {
        let series = chartSeries()
        if series.allSatisfy({ $0.bytes == 0 }) {
            emptyChart
        } else {
            Chart(series) { point in
                // No `.position(by:)` so up/down for the same day stack
                // at the same x — single bar per day, color-split.
                BarMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Bytes", point.bytes)
                )
                .foregroundStyle(by: .value("Direction", point.direction.localizedTitle))
                .cornerRadius(3)
            }
            .chartForegroundStyleScale([
                ChartDirection.up.localizedTitle: Color.blue,
                ChartDirection.down.localizedTitle: Color.green,
            ])
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let bytes = value.as(Int64.self) {
                            Text(ByteFormatter.string(bytes))
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartXAxis {
                // Striding by N days keeps the label count fixed even
                // when the bar count grows: 7d → daily, 14d → every 2nd
                // day, 30d → every 5th. With a string-categorical axis
                // labels would crowd at any range > 7.
                AxisMarks(values: .stride(by: .day, count: range.xAxisStrideDays)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: range.xAxisFormat, centered: true)
                        .font(.caption2)
                }
            }
        }
    }

    private var emptyChart: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No traffic recorded yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Connect the tunnel to start collecting daily usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent days")
                .font(.subheadline.weight(.semibold))
                .padding(.bottom, 8)

            let recent = recentEntriesForList()
            if recent.isEmpty {
                Text("No daily totals yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    DailyUsageRow(entry: entry)
                        .padding(.vertical, 8)
                }
            }
        }
        .card()
    }

    private var resetButton: some View {
        Button(role: .destructive) {
            showResetConfirm = true
        } label: {
            Label("Reset statistics", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(dailyUsage.entries.isEmpty)
    }

    // MARK: - Data shaping

    /// Entries whose day falls within the currently selected calendar
    /// window ending today. Filtering by date (not by entry count)
    /// keeps the summary card and the chart in agreement when usage is
    /// sparse — otherwise the summary would sum recorded entries from
    /// outside the window while the chart correctly renders zero bars.
    private func bucketedEntries() -> [DailyUsageEntry] {
        DailyUsage.entriesInWindow(dailyUsage.entries, days: range.dayCount)
    }

    /// Builds chart points covering exactly `range.dayCount` days,
    /// ending today. Days with no recorded traffic show as zero bars
    /// rather than gaps so the x-axis stays evenly spaced.
    private func chartSeries() -> [ChartPoint] {
        let window = range.dayCount
        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)

        let lookup = Dictionary(uniqueKeysWithValues: dailyUsage.entries.map { ($0.day, $0) })
        var points: [ChartPoint] = []
        points.reserveCapacity(window * 2)

        for offset in stride(from: window - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else {
                continue
            }
            let key = DailyUsage.dayKey(for: date, calendar: calendar)
            let entry = lookup[key]
            points.append(
                ChartPoint(
                    id: "\(key)-up",
                    date: date,
                    bytes: entry?.up ?? 0,
                    direction: .up
                )
            )
            points.append(
                ChartPoint(
                    id: "\(key)-down",
                    date: date,
                    bytes: entry?.down ?? 0,
                    direction: .down
                )
            )
        }
        return points
    }

    private func recentEntriesForList() -> [DailyUsageEntry] {
        // Show the same window the chart uses, but newest-first since
        // a vertical list reads top-down better as "most recent first".
        bucketedEntries().reversed()
    }

    // MARK: - Types

    enum Range: Int, CaseIterable, Identifiable {
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
        /// label count stays in the 6–8 range across all picker
        /// settings, leaving enough horizontal room that even the
        /// widest "M/d" label can't collide on a 360pt-wide chart.
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

    private enum ChartDirection {
        case up, down
        var localizedTitle: String {
            switch self {
            case .up: return String(localized: "Upload", bundle: .main)
            case .down: return String(localized: "Download", bundle: .main)
            }
        }
    }

    private struct ChartPoint: Identifiable {
        let id: String
        let date: Date
        let bytes: Int64
        let direction: ChartDirection
    }
}

private struct DailyUsageRow: View {
    let entry: DailyUsageEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.day)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                Text(formattedRelative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormatter.string(entry.total))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                HStack(spacing: 6) {
                    Label(ByteFormatter.string(entry.up), systemImage: "arrow.up")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.blue)
                    Label(ByteFormatter.string(entry.down), systemImage: "arrow.down")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.green)
                }
                .labelStyle(.titleAndIcon)
            }
        }
    }

    private var formattedRelative: String {
        // Best-effort localized relative day name ("Today", "Yesterday",
        // "Mon"). Falls back to the raw key when parsing fails.
        let parser = DateFormatter()
        parser.calendar = Calendar.current
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: entry.day) else { return "" }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today", bundle: .main) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday", bundle: .main) }

        let display = DateFormatter()
        display.calendar = calendar
        display.locale = Locale.autoupdatingCurrent
        display.setLocalizedDateFormatFromTemplate("EEE")
        return display.string(from: date)
    }
}

private struct StatisticsCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
    }
}

private extension View {
    func card() -> some View { modifier(StatisticsCard()) }
}
