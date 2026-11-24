import Library
import SwiftUI

struct DailyUsageRow: View {
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
