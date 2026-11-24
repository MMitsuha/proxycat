import Library
import SwiftUI

// MARK: - Row

struct ConnectionRow: View {
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
                    ProxyCatBadge(text: connection.rule)
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

struct NetworkBadge: View {
    let network: String

    var body: some View {
        ProxyCatBadge(text: network.uppercased(), tint: color)
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

struct ConnectionDetailSheet: View {
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
