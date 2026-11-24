import Foundation

// MARK: - Models (mirror mihomo's `/connections` snapshot; see
// tunnel/statistic/manager.go and constant/metadata.go)

public struct ConnectionMetadata: Codable, Hashable, Sendable {
    public let network: String
    public let type: String
    public let sourceIP: String
    public let destinationIP: String
    /// `,string` json tag → arrives as string in the wire format.
    public let sourcePort: String
    public let destinationPort: String
    public let host: String
    public let process: String
    public let processPath: String
    public let dnsMode: String?
    public let sniffHost: String?

    public var displayHost: String {
        // Mirror metacubexd's host column: prefer host (sniffed/SNI),
        // fall back to destinationIP. Either may be empty for very early
        // packets so we end up with a "—" placeholder downstream.
        if !host.isEmpty { return host }
        return destinationIP
    }

    public var displayPort: String {
        destinationPort
    }
}

public struct Connection: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let metadata: ConnectionMetadata
    public let upload: Int64
    public let download: Int64
    public let start: Date
    public let chains: [String]
    public let rule: String
    public let rulePayload: String

    /// Bytes/sec since the previous snapshot. Computed on the Swift side
    /// (see ConnectionsStore.diff) — not a wire field.
    public var uploadSpeed: Int64 = 0
    public var downloadSpeed: Int64 = 0

    /// Outermost hop in the proxy chain. mihomo's chain is reversed
    /// relative to display order (DIRECT/Proxy first), and this is the
    /// one users care about. Empty when no chain has been established yet.
    public var primaryChain: String { chains.first ?? "" }

    enum CodingKeys: String, CodingKey {
        case id, metadata, upload, download, start, chains, rule, rulePayload
    }
}

public struct ConnectionsSnapshot: Codable, Sendable {
    public let downloadTotal: Int64
    public let uploadTotal: Int64
    public let connections: [Connection]?
    public let memory: UInt64?
}
