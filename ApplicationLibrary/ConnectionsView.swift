import Library
import SwiftUI

public struct ConnectionsView: View {
    @EnvironmentObject private var profile: ExtensionProfile
    @ObservedObject private var settings = RuntimeSettings.shared

    @StateObject private var store = ConnectionsStore()
    @State private var query: String = ""
    @State private var confirmCloseAll: Bool = false
    @State private var detail: Connection?

    public init() {}

    public var body: some View {
        Group {
            if !profile.isConnected {
                empty(
                    symbol: "powerplug.portrait",
                    title: String(localized: "Connect first to view connections")
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
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { syncStreaming() }
        .onDisappear { store.stop() }
        // Defensive: if the tunnel drops or the controller flag flips
        // mid-view, stop the WS retry loop and let the empty state take
        // over instead of letting the store hammer a closed socket.
        .onChange(of: profile.isConnected) { _, _ in syncStreaming() }
        .onChange(of: settings.disableExternalController) { _, _ in syncStreaming() }
        .sheet(item: $detail) { conn in
            ConnectionDetailSheet(connection: conn)
        }
    }

    private func syncStreaming() {
        if profile.isConnected, !settings.disableExternalController {
            store.start()
        } else {
            store.stop()
        }
    }

    @ViewBuilder
    private var content: some View {
        let filtered = filteredConnections
        VStack(spacing: 0) {
            summaryBar
            if let err = store.loadError, store.connections.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.connections.isEmpty {
                VStack(spacing: 8) {
                    if store.isStreaming {
                        Image(systemName: "tray")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("No active connections")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered) { conn in
                        ConnectionRow(connection: conn)
                            .contentShape(Rectangle())
                            .onTapGesture { detail = conn }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await store.close(id: conn.id) }
                                } label: {
                                    Label("Close", systemImage: "xmark.circle")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    confirmCloseAll = true
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .disabled(store.connections.isEmpty)
            }
        }
        .alert("Close all connections?", isPresented: $confirmCloseAll) {
            Button("Close all", role: .destructive) {
                Task { await store.closeAll() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var summaryBar: some View {
        HStack(spacing: 16) {
            Label {
                Text("\(store.connections.count) active")
                    .font(.subheadline.weight(.medium))
            } icon: {
                Circle()
                    .fill(store.isStreaming ? Color.green : .gray)
                    .frame(width: 8, height: 8)
            }
            Spacer()
            Label(ByteFormatter.string(store.uploadTotal), systemImage: "arrow.up")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Label(ByteFormatter.string(store.downloadTotal), systemImage: "arrow.down")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var filteredConnections: [Connection] {
        guard !query.isEmpty else { return store.connections }
        let needle = query.lowercased()
        return store.connections.filter { conn in
            if conn.metadata.host.lowercased().contains(needle) { return true }
            if conn.metadata.destinationIP.contains(needle) { return true }
            if conn.metadata.sourceIP.contains(needle) { return true }
            if conn.metadata.process.lowercased().contains(needle) { return true }
            if conn.rule.lowercased().contains(needle) { return true }
            if conn.chains.contains(where: { $0.lowercased().contains(needle) }) { return true }
            return false
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

// MARK: - Row

private struct ConnectionRow: View {
    let connection: Connection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(displayHost)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                NetworkBadge(network: connection.metadata.network)
            }
            HStack(spacing: 8) {
                if !connection.primaryChain.isEmpty {
                    Text(connection.primaryChain)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
                if !connection.rule.isEmpty {
                    Text(connection.rule)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(ageString)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label(ByteFormatter.rate(connection.downloadSpeed), systemImage: "arrow.down")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Label(ByteFormatter.rate(connection.uploadSpeed), systemImage: "arrow.up")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(totalString)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var displayHost: String {
        let host = connection.metadata.displayHost
        let port = connection.metadata.displayPort
        if !host.isEmpty, !port.isEmpty, port != "0" {
            return "\(host):\(port)"
        }
        return host.isEmpty ? "—" : host
    }

    private var ageString: String {
        let interval = max(0, Date().timeIntervalSince(connection.start))
        let s = Int(interval)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        return "\(h / 24)d"
    }

    private var totalString: String {
        let total = connection.upload + connection.download
        return ByteFormatter.string(total)
    }
}

private struct NetworkBadge: View {
    let network: String

    var body: some View {
        Text(network.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch network.lowercased() {
        case "tcp": return .blue
        case "udp": return .purple
        default: return .secondary
        }
    }
}

// MARK: - Detail sheet

private struct ConnectionDetailSheet: View {
    let connection: Connection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Target") {
                    field("Host", connection.metadata.host)
                    field("Destination", "\(connection.metadata.destinationIP):\(connection.metadata.destinationPort)")
                    field("Network", connection.metadata.network)
                    field("Type", connection.metadata.type)
                    if let sniff = connection.metadata.sniffHost, !sniff.isEmpty {
                        field("SNI", sniff)
                    }
                }
                Section("Source") {
                    field("Address", "\(connection.metadata.sourceIP):\(connection.metadata.sourcePort)")
                    if !connection.metadata.process.isEmpty {
                        field("Process", connection.metadata.process)
                    }
                    if !connection.metadata.processPath.isEmpty {
                        field("Process Path", connection.metadata.processPath)
                    }
                }
                Section("Routing") {
                    field("Rule", connection.rule)
                    if !connection.rulePayload.isEmpty {
                        field("Payload", connection.rulePayload)
                    }
                    field("Chain", connection.chains.joined(separator: " ← "))
                }
                Section("Traffic") {
                    field("Upload", ByteFormatter.string(connection.upload))
                    field("Download", ByteFormatter.string(connection.download))
                    field("Started", connection.start.formatted(date: .abbreviated, time: .standard))
                    field("ID", connection.id)
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func field(_ key: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "—" : value)
                .font(.subheadline.monospaced())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
