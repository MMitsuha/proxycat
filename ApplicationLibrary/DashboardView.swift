import Library
import NetworkExtension
import SwiftUI

public struct DashboardView: View {
    @EnvironmentObject private var environment: ExtensionEnvironment
    @EnvironmentObject private var profile: ExtensionProfile
    @EnvironmentObject private var commandClient: CommandClient
    @EnvironmentObject private var profileStore: ProfileStore

    @State private var connectError: String?

    public init() {}

    public var body: some View {
        List {
            Section {
                statusCard
            }
            Section("Traffic") {
                TrafficRow(label: "Up", value: ByteFormatter.rate(commandClient.traffic.up))
                TrafficRow(label: "Down", value: ByteFormatter.rate(commandClient.traffic.down))
                TrafficRow(label: "Up total", value: ByteFormatter.string(commandClient.traffic.upTotal))
                TrafficRow(label: "Down total", value: ByteFormatter.string(commandClient.traffic.downTotal))
                TrafficRow(label: "Connections", value: "\(commandClient.traffic.connections)")
            }
            Section("Profile") {
                if let active = profileStore.active {
                    Text(active.name)
                } else {
                    Text("No profile selected")
                        .foregroundStyle(.secondary)
                }
                NavigationLink("Manage Profiles") { ProfileListView() }
            }
        }
        .navigationTitle("ProxyCat")
        .alert("Cannot connect", isPresented: .constant(connectError != nil)) {
            Button("OK") { connectError = nil }
        } message: {
            Text(connectError ?? "")
        }
    }

    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(profile.isConnected ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.headline)
                Spacer()
            }
            Button(action: toggle) {
                Text(profile.isConnected ? "Disconnect" : "Connect")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(profile.isConnected ? .red : .accentColor)
            .disabled(profileStore.active == nil)
        }
    }

    private var statusText: String {
        switch profile.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .disconnected: return "Disconnected"
        case .reasserting: return "Reasserting…"
        case .invalid: return "Not configured"
        @unknown default: return "Unknown"
        }
    }

    private func toggle() {
        if profile.isConnected {
            profile.stop()
            return
        }
        guard let active = profileStore.active else {
            connectError = "Pick a profile first."
            return
        }
        do {
            let yaml = try profileStore.loadActiveContent()
            try profile.start(configContent: yaml)
            _ = active // silence unused
        } catch {
            connectError = error.localizedDescription
        }
    }
}

private struct TrafficRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
    }
}
