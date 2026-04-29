import Library
import NetworkExtension
import SwiftUI

public struct DashboardView: View {
    @EnvironmentObject private var environment: ExtensionEnvironment
    @EnvironmentObject private var profile: ExtensionProfile
    @EnvironmentObject private var commandClient: CommandClient
    @EnvironmentObject private var profileStore: ProfileStore

    @State private var connectError: String?

    @AppStorage(AppConfiguration.disableExternalControllerKey)
    private var disableExternalController = false

    public init() {}

    public var body: some View {
        VStack(spacing: 14) {
            statusCard
            trafficGrid
            bottomCard
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("ProxyCat")
        .navigationBarTitleDisplayMode(.large)
        .alert("Cannot connect", isPresented: .constant(connectError != nil)) {
            Button("OK") { connectError = nil }
        } message: {
            Text(connectError ?? "")
        }
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
                    Image(systemName: profile.isConnected ? "stop.fill" : "play.fill")
                    Text(profile.isConnected ? String(localized: "Disconnect") : String(localized: "Connect"))
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(profile.isConnected ? .red : .accentColor)
            .disabled(profileStore.active == nil)

            if profile.isConnected, !disableExternalController, let url = URL(string: "http://127.0.0.1:9090/ui/") {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "safari")
                        Text("Open Web UI")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                    }
                    .font(.subheadline)
                }
            }

            if profile.isConnected, !disableExternalController {
                NavigationLink {
                    ProxiesView()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "globe.asia.australia")
                        Text("Proxies")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
        .card()
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
            VStack(spacing: 2) {
                Text("\(commandClient.traffic.connections)")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(profile.isConnected ? Color.primary : .secondary)
                Text("active")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56)
        }
        .card()
    }

    // MARK: - Actions

    private func toggle() {
        if profile.isConnected {
            profile.stop()
            return
        }
        guard let active = profileStore.active else {
            connectError = String(localized: "Pick a profile first.")
            return
        }
        // Read the YAML off-main (could be tens of KB on cold storage)
        // and start the tunnel asynchronously so the manager save in
        // ExtensionProfile.start can be awaited without blocking the UI.
        let url = FilePath.profilesDirectory.appendingPathComponent(active.fileName)
        Task {
            do {
                let yaml = try await Task.detached(priority: .userInitiated) {
                    try String(contentsOf: url, encoding: .utf8)
                }.value
                try await profile.start(configContent: yaml, disableExternalController: disableExternalController)
            } catch {
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
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct MemoryBar: View {
    let memory: MemoryStats
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                    .font(.subheadline)
                    .foregroundStyle(tint)
                Text("Memory")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
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

// MARK: - Card modifier

private struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
    }
}

private extension View {
    func card() -> some View { modifier(Card()) }
}
