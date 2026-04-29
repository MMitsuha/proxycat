import Library
import SwiftUI

public struct ProxiesView: View {
    @EnvironmentObject private var profile: ExtensionProfile
    @ObservedObject private var settings = RuntimeSettings.shared
    @StateObject private var store = ProxiesStore()

    public init() {}

    public var body: some View {
        Group {
            if !profile.isConnected {
                empty(
                    symbol: "powerplug.portrait",
                    title: String(localized: "Connect first to manage proxies")
                )
            } else if settings.disableExternalController {
                empty(
                    symbol: "network.slash",
                    title: String(localized: "Web Controller is off")
                )
            } else {
                content
            }
        }
        .navigationTitle("Proxies")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if let err = store.loadError, store.groups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry") { Task { await store.refresh() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.groups.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(store.groups, id: \.name) { group in
                    Section {
                        if !store.isCollapsed(group.name) {
                            ForEach(group.all ?? [], id: \.self) { name in
                                ProxyRow(
                                    name: name,
                                    node: store.nodeMap[name],
                                    isSelected: group.now == name,
                                    isInteractive: group.isSelector,
                                    isPending: store.isSelecting(group: group.name, node: name),
                                    onTap: {
                                        Task { await store.select(group: group, name: name) }
                                    }
                                )
                            }
                        }
                    } header: {
                        ProxyGroupHeader(
                            group: group,
                            isCollapsed: store.isCollapsed(group.name),
                            isTesting: store.groupTesting.contains(group.name),
                            onToggle: { withAnimation { store.toggleCollapsed(group.name) } },
                            onTest: { Task { await store.testGroup(group) } }
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                }
            }
        }
    }

    private func empty(symbol: String, title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Group header

private struct ProxyGroupHeader: View {
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
                        Text(group.type)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
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

private struct ProxyRow: View {
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

private struct LatencyPill: View {
    let ms: Int?

    var body: some View {
        Text(label)
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
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
