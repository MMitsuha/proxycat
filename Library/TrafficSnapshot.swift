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

public enum ByteFormatter {
    private static let bcf: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .binary
        return f
    }()

    public static func string(_ bytes: Int64) -> String {
        bcf.string(fromByteCount: bytes)
    }

    public static func rate(_ bytesPerSecond: Int64) -> String {
        bcf.string(fromByteCount: bytesPerSecond) + "/s"
    }
}
