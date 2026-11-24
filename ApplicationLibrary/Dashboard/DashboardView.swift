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
        ScrollView {
            VStack(spacing: ProxyCatUI.pageSpacing) {
                statusCard
                trafficGrid
                bottomCard
            }
            .proxyCatPage()
        }
        .background(ProxyCatUI.pageBackground.ignoresSafeArea())
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
            .accessibilityIdentifier("dashboard.connect")

            webUIRow
            proxiesRow
        }
        .proxyCatCard()
        .accessibilityIdentifier("dashboard.status")
    }

    @ViewBuilder
    private var webUIRow: some View {
        let isAvailable = profile.isConnected && !settings.disableExternalController
        if isAvailable, let url = AppConfiguration.webUIURL {
            Link(destination: url) {
                ProxyCatActionRow(
                    title: "Open Web UI",
                    systemImage: "safari",
                    trailingImage: "arrow.up.right"
                )
            }
            .accessibilityIdentifier("dashboard.webUI")
        } else {
            ProxyCatActionRow(
                title: "Open Web UI",
                systemImage: "safari",
                trailingImage: "arrow.up.right",
                isEnabled: false
            )
            .accessibilityIdentifier("dashboard.webUI")
        }
    }

    @ViewBuilder
    private var proxiesRow: some View {
        if profile.isConnected {
            NavigationLink {
                ProxiesView(transport: commandClient)
            } label: {
                ProxyCatActionRow(
                    title: "Proxies",
                    systemImage: "globe.asia.australia"
                )
            }
            .accessibilityIdentifier("dashboard.proxies")
        } else {
            ProxyCatActionRow(
                title: "Proxies",
                systemImage: "globe.asia.australia",
                isEnabled: false
            )
            .accessibilityIdentifier("dashboard.proxies")
        }
    }

    @ViewBuilder
    private var profilePill: some View {
        if let active = profileStore.active {
            ProxyCatBadge(
                text: active.name,
                tint: .accentColor,
                systemImage: "doc.text",
                font: .caption.weight(.medium),
                horizontalPadding: 10,
                verticalPadding: 5
            )
            .lineLimit(1)
        } else {
            ProxyCatBadge(
                text: String(localized: "No profile", bundle: .main),
                tint: .gray,
                systemImage: "doc.text",
                font: .caption.weight(.medium),
                horizontalPadding: 10,
                verticalPadding: 5
            )
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                trafficCards
            }
            VStack(spacing: 12) {
                trafficCards
            }
        }
        .accessibilityIdentifier("dashboard.traffic")
    }

    @ViewBuilder
    private var trafficCards: some View {
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

    // MARK: - Memory + connections

    private var bottomCard: some View {
        HStack(spacing: 12) {
            MemoryBar(memory: commandClient.memory, live: profile.isConnected)
            Divider().frame(height: 36)
            connectionsCell
        }
        .proxyCatCard()
        .accessibilityIdentifier("dashboard.memory")
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
            .accessibilityIdentifier("dashboard.connections")
        } else {
            connectionsLabel(isInteractive: false)
                .accessibilityIdentifier("dashboard.connections")
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
