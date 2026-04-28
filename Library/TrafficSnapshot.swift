import Foundation

public struct TrafficSnapshot: Equatable, Sendable {
    public let up: Int64
    public let down: Int64
    public let upTotal: Int64
    public let downTotal: Int64
    public let connections: Int64

    public static let zero = TrafficSnapshot(up: 0, down: 0, upTotal: 0, downTotal: 0, connections: 0)

    public init(up: Int64, down: Int64, upTotal: Int64, downTotal: Int64, connections: Int64) {
        self.up = up
        self.down = down
        self.upTotal = upTotal
        self.downTotal = downTotal
        self.connections = connections
    }
}

/// Memory state of the Network Extension process. Values are produced by
/// the extension itself and shipped to the host via the shared
/// `traffic.json` snapshot — the host process can NOT read the extension's
/// memory directly, the kernels are separate.
public struct MemoryStats: Equatable, Sendable {
    /// Bytes the kernel currently bills against the process. This is the
    /// number jetsam compares to the per-process memory limit.
    public let resident: Int
    /// Bytes still available before jetsam terminates the extension.
    /// Sourced from `os_proc_available_memory()`.
    public let available: Int

    public static let zero = MemoryStats(resident: 0, available: 0)

    public init(resident: Int, available: Int) {
        self.resident = resident
        self.available = available
    }

    /// Best-effort estimate of the per-process memory limit on this device.
    /// Apple doesn't expose it publicly so we infer it from
    /// `resident + available`. Caller should treat as "rough budget".
    public var estimatedLimit: Int {
        resident + available
    }

    /// 0...1 fraction of the budget consumed.
    public var fraction: Double {
        let total = estimatedLimit
        guard total > 0 else { return 0 }
        return min(1.0, Double(resident) / Double(total))
    }
}

public enum ByteFormatter {
    private static let bcf: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .binary
        // The default "Zero KB" is ugly in compact gauges.
        f.allowsNonnumericFormatting = false
        return f
    }()

    public static func string(_ bytes: Int64) -> String {
        bcf.string(fromByteCount: bytes)
    }

    public static func rate(_ bytesPerSecond: Int64) -> String {
        bcf.string(fromByteCount: bytesPerSecond) + "/s"
    }
}
