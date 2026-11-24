import Library
import SwiftUI

// MARK: - Group header

struct ProxyGroupHeader: View {
    let group: Proxy
    let isCollapsed: Bool
    let isTesting: Bool
    let onToggle: () -> Void
    let onTest: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Tappable left-side area: chevron + name/type/now stack.
            // Whole region forwards taps to onToggle without swallowing
            // the trailing test button (which lives outside this HStack).
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        ProxyCatBadge(text: group.type, tint: Color.accentColor)
                    }
                    if let now = group.now, !now.isEmpty {
                        Text(now)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text(isCollapsed ? "Expand" : "Collapse"))

            Button(action: onTest) {
                if isTesting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "stopwatch")
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Test latency"))
            .disabled(isTesting)
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }
}

// MARK: - Node row

struct ProxyRow: View {
    let name: String
    let node: Proxy?
    let isSelected: Bool
    let isInteractive: Bool
    let isPending: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: { if isInteractive { onTap() } }) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let type = node?.type {
                        Text(type)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                LatencyPill(ms: node?.latestDelay)
            }
            .opacity(isPending ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive || isPending)
    }
}

// MARK: - Latency pill

struct LatencyPill: View {
    let ms: Int?

    var body: some View {
        ProxyCatBadge(
            text: label,
            tint: color,
            font: .caption.monospacedDigit().weight(.semibold),
            horizontalPadding: 8,
            verticalPadding: 3
        )
    }

    private var label: String {
        guard let ms else { return "—" }
        return "\(ms) ms"
    }

    /// Same thresholds metacubexd's default `latencyQualityMap` uses.
    private var color: Color {
        guard let ms, ms > 0 else { return .secondary }
        if ms < 300 { return .green }
        if ms < 800 { return .yellow }
        return .red
    }
}
