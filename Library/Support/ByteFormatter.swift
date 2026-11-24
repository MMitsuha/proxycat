import Foundation

public enum ByteFormatter {
    /// Network-traffic style: KiB / MiB / GiB. Used for live traffic
    /// gauges where the rate makes binary units more natural.
    // ByteCountFormatter is documented as safe to read concurrently
    // after configuration; Foundation just doesn't formally declare
    // Sendable, so we tell the compiler we've checked.
    nonisolated(unsafe) private static let trafficFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .binary
        // The default "Zero KB" is ugly in compact gauges.
        f.allowsNonnumericFormatting = false
        return f
    }()

    /// File-system style: KB / MB / GB. Used for storage indicators
    /// (cache size, log file size, bundled-asset size). Single shared
    /// instance because `ByteCountFormatter` allocations show up in
    /// ApplicationLibrary's hot paths under heavy log streaming.
    nonisolated(unsafe) private static let fileFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    public static func string(_ bytes: Int64) -> String {
        trafficFormatter.string(fromByteCount: bytes)
    }

    public static func rate(_ bytesPerSecond: Int64) -> String {
        trafficFormatter.string(fromByteCount: bytesPerSecond) + "/s"
    }

    /// File-system byte string (1 KB = 1000 B). Use for cache size,
    /// log file size, and bundled-asset size displays — anywhere the
    /// system "About → Storage" UI would be the natural reference.
    public static func fileSize(_ bytes: Int64) -> String {
        fileFormatter.string(fromByteCount: bytes)
    }
}
