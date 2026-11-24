import Library
import SwiftUI

// MARK: - Components

struct TrafficCard: View {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color
    let rate: Int64
    let total: Int64
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProxyCatMetricHeader(title: title, systemImage: symbol, tint: color)
                Spacer()
            }
            Text(ByteFormatter.rate(rate))
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(live ? Color.primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(ByteFormatter.string(total))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .proxyCatCard()
    }
}

struct MemoryBar: View {
    let memory: MemoryStats
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProxyCatMetricHeader(title: "Memory", systemImage: "memorychip", tint: tint)
                Spacer()
                Text(displayValue)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(live ? .primary : .secondary)
            }
            ProgressView(value: live ? memory.fraction : 0)
                .progressViewStyle(.linear)
                .tint(tint)
        }
    }

    private var displayValue: String {
        guard live, memory.estimatedLimit > 0 else { return "—" }
        let used = ByteFormatter.string(Int64(memory.resident))
        let total = ByteFormatter.string(Int64(memory.estimatedLimit))
        return "\(used) / \(total)"
    }

    private var tint: Color {
        guard memory.available > 0 else { return .accentColor }
        if memory.available < 3 * 1024 * 1024 { return .red }
        if memory.available < 6 * 1024 * 1024 { return .orange }
        return .accentColor
    }
}

/// Pulsing dot for the status header.
struct StatusDot: View {
    let color: Color
    let pulsing: Bool

    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 18, height: 18)
                    .scaleEffect(scale)
                    .opacity(2 - scale)
                    .animation(
                        .easeOut(duration: 1.0).repeatForever(autoreverses: false),
                        value: scale
                    )
                    .onAppear { scale = 1.6 }
                    .onDisappear { scale = 1 }
            }
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
        }
        .frame(width: 18, height: 18)
    }
}
