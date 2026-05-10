import Library
import NetworkExtension
import SwiftUI

public struct DashboardView: View {
    @Environment(ExtensionEnvironment.self) private var environment
    @Environment(ExtensionProfile.self) private var profile
    @Environment(CommandClient.self) private var commandClient
    @Environment(ProfileStore.self) private var profileStore
    @Environment(RuntimeSettings.self) private var settings

    @State private var connectError: String?
    /// Held true between a Connect tap and the OS-level NEVPNStatus
    /// finally moving off `.disconnected`. `ExtensionProfile.start()`
    /// awaits a manager save before calling `startVPNTunnel`, so the
    /// system status notification can lag behind the tap by a frame or
    /// two — `isInTransition` alone leaves a window where a second tap
    /// would queue another start and surface a confusing NE error.
    @State private var isStarting: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: ProxyCatUI.pageSpacing) {
            statusCard
            trafficGrid
            bottomCard
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ProxyCatUI.pageHorizontalPadding)
        .padding(.top, ProxyCatUI.pageTopPadding)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("ProxyCat")
        .navigationBarTitleDisplayMode(.large)
        // Once OS status moves off `.disconnected`, hand the button-disabled
        // state back to `isInTransition` / `profile.isConnected`. (Synchronous
        // start failures don't move status; the `catch` arm in `toggle`
        // clears `isStarting` itself.)
        .onChange(of: profile.status) { _, _ in isStarting = false }
        .errorAlert($connectError, title: "Cannot connect")
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatusDot(color: statusColor, pulsing: profile.status == .connecting)
                Text(statusText)
                    .font(.title3.weight(.semibold))
                Spacer()
                profilePill
            }

            Button(action: toggle) {
                HStack(spacing: 6) {
                    if isInTransition {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: profile.isConnected ? "stop.fill" : "play.fill")
                    }
                    Text(toggleButtonLabel)
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(profile.isConnected ? .red : .accentColor)
            .disabled(profileStore.active == nil || isInTransition || isStarting)

            webUIRow
            proxiesRow
        }
        .proxyCatCard()
    }

    @ViewBuilder
    private var webUIRow: some View {
        let isAvailable = profile.isConnected && !settings.disableExternalController
        if isAvailable, let url = URL(string: "http://127.0.0.1:9090/ui/") {
            Link(destination: url) {
                dashboardActionLabel(
                    title: "Open Web UI",
                    systemImage: "safari",
                    trailingImage: "arrow.up.right",
                    isAvailable: true
                )
            }
        } else {
            dashboardActionLabel(
                title: "Open Web UI",
                systemImage: "safari",
                trailingImage: "arrow.up.right",
                isAvailable: false
            )
        }
    }

    @ViewBuilder
    private var proxiesRow: some View {
        if profile.isConnected {
            NavigationLink {
                ProxiesView(transport: commandClient)
            } label: {
                dashboardActionLabel(
                    title: "Proxies",
                    systemImage: "globe.asia.australia",
                    trailingImage: "chevron.right",
                    isAvailable: true
                )
            }
        } else {
            dashboardActionLabel(
                title: "Proxies",
                systemImage: "globe.asia.australia",
                trailingImage: "chevron.right",
                isAvailable: false
            )
        }
    }

    private func dashboardActionLabel(
        title: LocalizedStringKey,
        systemImage: String,
        trailingImage: String,
        isAvailable: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
            Spacer()
            Image(systemName: trailingImage)
                .font(.caption)
        }
        .font(.subheadline)
        .foregroundStyle(isAvailable ? Color.accentColor : Color.secondary)
        .opacity(isAvailable ? 1 : 0.48)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var profilePill: some View {
        if let active = profileStore.active {
            Label(active.name, systemImage: "doc.text")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .foregroundStyle(.tint)
        } else {
            Label("No profile", systemImage: "doc.text")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.gray.opacity(0.18), in: Capsule())
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch profile.status {
        case .connected: return .green
        case .connecting, .reasserting: return .orange
        case .disconnecting: return .yellow
        case .disconnected, .invalid: return .gray
        @unknown default: return .gray
        }
    }

    private var statusText: String {
        switch profile.status {
        case .connected: return String(localized: "Connected")
        case .connecting: return String(localized: "Connecting")
        case .disconnecting: return String(localized: "Disconnecting")
        case .disconnected: return String(localized: "Disconnected")
        case .reasserting: return String(localized: "Reasserting")
        case .invalid: return String(localized: "Not configured")
        @unknown default: return String(localized: "Unknown")
        }
    }

    private var isInTransition: Bool {
        switch profile.status {
        case .connecting, .disconnecting, .reasserting: return true
        default: return false
        }
    }

    private var toggleButtonLabel: String {
        if isInTransition { return statusText }
        return profile.isConnected ? String(localized: "Disconnect") : String(localized: "Connect")
    }

    // MARK: - Traffic

    private var trafficGrid: some View {
        HStack(spacing: 12) {
            TrafficCard(
                title: "Upload",
                symbol: "arrow.up.circle.fill",
                color: .blue,
                rate: commandClient.traffic.up,
                total: commandClient.traffic.upTotal,
                live: profile.isConnected
            )
            TrafficCard(
                title: "Download",
                symbol: "arrow.down.circle.fill",
                color: .green,
                rate: commandClient.traffic.down,
                total: commandClient.traffic.downTotal,
                live: profile.isConnected
            )
        }
    }

    // MARK: - Memory + connections

    private var bottomCard: some View {
        HStack(spacing: 12) {
            MemoryBar(memory: commandClient.memory, live: profile.isConnected)
            Divider().frame(height: 36)
            connectionsCell
        }
        .proxyCatCard()
    }

    @ViewBuilder
    private var connectionsCell: some View {
        let isInteractive = profile.isConnected
        if isInteractive {
            NavigationLink {
                ConnectionsView(transport: commandClient)
            } label: {
                connectionsLabel(isInteractive: true)
            }
            .buttonStyle(.plain)
        } else {
            connectionsLabel(isInteractive: false)
        }
    }

    private func connectionsLabel(isInteractive: Bool) -> some View {
        HStack(spacing: 4) {
            VStack(spacing: 2) {
                Text("\(commandClient.traffic.connections)")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isInteractive ? Color.primary : Color.secondary)
                Text("active")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .opacity(isInteractive ? 1 : 0.35)
        }
        .frame(width: 72)
        .opacity(isInteractive ? 1 : 0.48)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func toggle() {
        // Disabled-state guard — the button itself is disabled during
        // these statuses, but a stale tap before SwiftUI re-renders
        // would otherwise call start()/stop() against a transitioning
        // tunnel and surface confusing NEVPNError failures.
        if isInTransition || isStarting { return }
        if profile.isConnected {
            profile.stop()
            return
        }
        guard profileStore.active != nil else {
            connectError = String(localized: "Pick a profile first.")
            return
        }
        // Lock the button before kicking off the start task. The system
        // status notification only fires after `ExtensionProfile.start()`
        // finishes its manager save and `startVPNTunnel` reaches the
        // extension; without this local guard, a second tap during that
        // window queues a duplicate start and surfaces an NEVPN error.
        // `.onChange(of: profile.status)` clears the flag once the OS
        // takes over (or when a synchronous failure leaves status put).
        isStarting = true
        // The Go core reads the active profile YAML and runtime settings
        // from the App Group container itself, so all the host has to do
        // is await the manager save inside ExtensionProfile.start().
        Task {
            do {
                try await profile.start()
            } catch {
                isStarting = false
                connectError = error.localizedDescription
            }
        }
    }
}

// MARK: - Components

private struct TrafficCard: View {
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

private struct MemoryBar: View {
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
private struct StatusDot: View {
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
