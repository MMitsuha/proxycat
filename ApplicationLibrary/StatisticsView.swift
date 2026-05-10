import Charts
import Library
import SwiftUI

public struct StatisticsView: View {
    @Environment(DailyUsageStore.self) private var dailyUsage

    @State private var range: Range = .week
    @State private var showResetConfirm = false

    public init() {}

    public var body: some View {
        // Build the windowed model once per body evaluation. All cards need
        // the same slice, and SwiftUI re-evaluates body on every dailyUsage
        // publish; threading a single model through avoids duplicate reduces.
        let model = usageModel()
        return ScrollView {
            VStack(spacing: ProxyCatUI.pageSpacing) {
                overviewCard(model)
                chartCard(model)
                listCard(model)
                resetAction
            }
            .padding(.horizontal, ProxyCatUI.pageHorizontalPadding)
            .padding(.top, ProxyCatUI.pageTopPadding)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        // .alert (modal) instead of .confirmationDialog: iOS 26 renders
        // confirmationDialog as a popover whose full-screen dismiss
        // region eats a rapid second tap on the trigger button, making
        // it look like Reset needs two taps. See SettingsView.
        .alert(
            "Reset statistics?",
            isPresented: $showResetConfirm
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

    private func overviewCard(_ model: UsageModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProxyCatMetricHeader(
                title: "Usage",
                systemImage: "chart.bar.xaxis",
                tint: .accentColor,
                iconFont: .subheadline,
                titleFont: .subheadline.weight(.semibold)
            )

            rangePicker

            Divider()

            summaryGrid(model)
        }
        .proxyCatCard()
    }

    private func summaryGrid(_ model: UsageModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            summaryColumn(
                title: "Total",
                value: ByteFormatter.string(model.total),
                color: .accentColor,
                symbol: "sum"
            )
            Divider().frame(height: 36)
            summaryColumn(
                title: "Upload",
                value: ByteFormatter.string(model.totalUp),
                color: .blue,
                symbol: "arrow.up.circle.fill"
            )
            Divider().frame(height: 36)
            summaryColumn(
                title: "Download",
                value: ByteFormatter.string(model.totalDown),
                color: .green,
                symbol: "arrow.down.circle.fill"
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func summaryColumn(title: LocalizedStringKey, value: String, color: Color, symbol: String) -> some View {
        VStack(spacing: 4) {
            ProxyCatMetricHeader(
                title: title,
                systemImage: symbol,
                tint: color,
                iconFont: .caption2,
                titleFont: .caption2.weight(.medium)
            )
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func chartCard(_ model: UsageModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                ProxyCatMetricHeader(
                    title: "Daily Traffic",
                    systemImage: "chart.bar.fill",
                    tint: .accentColor,
                    iconFont: .subheadline,
                    titleFont: .subheadline.weight(.semibold)
                )
                Spacer()
                chartLegend
            }

            chartContent(series: model.series)
                .frame(height: 180)
        }
        .proxyCatCard()
    }

    private var chartLegend: some View {
        HStack(spacing: 10) {
            legendItem("Upload", color: .blue)
            legendItem("Download", color: .green)
        }
    }

    private func legendItem(_ title: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func chartContent(series: [ChartPoint]) -> some View {
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
            .chartLegend(.hidden)
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

    private func listCard(_ model: UsageModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ProxyCatMetricHeader(
                title: "Recent Days",
                systemImage: "calendar",
                tint: .accentColor,
                iconFont: .subheadline,
                titleFont: .subheadline.weight(.semibold)
            )

            if model.recent.isEmpty {
                emptyList
            } else {
                ForEach(Array(model.recent.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    DailyUsageRow(entry: entry)
                        .padding(.vertical, 8)
                }
            }
        }
        .proxyCatCard()
    }

    private var emptyList: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("No daily totals yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var resetAction: some View {
        Button(role: .destructive) {
            showResetConfirm = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                Text("Reset Statistics")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .opacity(dailyUsage.entries.isEmpty ? 0.35 : 1)
            }
            .font(.subheadline)
            .foregroundStyle(dailyUsage.entries.isEmpty ? Color.secondary : Color.red)
            .opacity(dailyUsage.entries.isEmpty ? 0.48 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(dailyUsage.entries.isEmpty)
        .proxyCatCard()
    }

    // MARK: - Data shaping

    private func usageModel() -> UsageModel {
        let bucketed = bucketedEntries()
        let totalUp = bucketed.reduce(into: Int64(0)) { $0 &+= $1.up }
        let totalDown = bucketed.reduce(into: Int64(0)) { $0 &+= $1.down }
        return UsageModel(
            recent: Array(bucketed.reversed()),
            series: chartSeries(),
            totalUp: totalUp,
            totalDown: totalDown
        )
    }

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

    private struct UsageModel {
        let recent: [DailyUsageEntry]
        let series: [ChartPoint]
        let totalUp: Int64
        let totalDown: Int64

        var total: Int64 { totalUp &+ totalDown }
    }
}

private struct DailyUsageRow: View {
    let entry: DailyUsageEntry

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.day)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(formattedRelative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(ByteFormatter.string(entry.total))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                HStack(spacing: 8) {
                    directionAmount(ByteFormatter.string(entry.up), systemImage: "arrow.up", color: .blue)
                    directionAmount(ByteFormatter.string(entry.down), systemImage: "arrow.down", color: .green)
                }
            }
        }
    }

    private func directionAmount(_ value: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(color)
        .labelStyle(.titleAndIcon)
    }

    private var formattedRelative: String {
        // Best-effort localized relative day name ("Today", "Yesterday",
        // "Mon"). Falls back to the raw key when parsing fails.
        guard let date = Self.date(fromDayKey: entry.day) else { return "" }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today", bundle: .main) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday", bundle: .main) }

        return date.formatted(Date.FormatStyle().weekday(.abbreviated))
    }

    private static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }

        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
