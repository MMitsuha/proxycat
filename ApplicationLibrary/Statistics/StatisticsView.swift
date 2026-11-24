import Charts
import Library
import SwiftUI

public struct StatisticsView: View {
    @Environment(DailyUsageStore.self) private var dailyUsage

    @State private var range: StatisticsRange = .week
    @State private var showResetConfirm = false

    public init() {}

    public var body: some View {
        // Build the windowed model once per body evaluation. All cards need
        // the same slice, and SwiftUI re-evaluates body on every dailyUsage
        // publish; threading a single model through avoids duplicate reduces.
        let model = StatisticsUsage.model(entries: dailyUsage.entries, range: range)
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
            ForEach(StatisticsRange.allCases) { r in
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
}
