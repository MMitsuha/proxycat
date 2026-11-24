import Foundation

/// Log level enum used as both the on-wire identifier (Go's
/// `mihomo/log.LogLevel`, 0=DEBUG…3=ERROR) and the host-side display
/// filter cutoff (`silent` shows nothing). `silent` is a UI-only state;
/// the extension never produces an event at that level.
public enum LogLevel: Int, CaseIterable, Identifiable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case silent = 4

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .debug: return String(localized: "Debug", bundle: .main)
        case .info: return String(localized: "Info", bundle: .main)
        case .warning: return String(localized: "Warning", bundle: .main)
        case .error: return String(localized: "Error", bundle: .main)
        case .silent: return String(localized: "Silent", bundle: .main)
        }
    }

    public var symbolName: String {
        switch self {
        case .debug: return "ladybug"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .silent: return "speaker.slash"
        }
    }
}

public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let level: LogLevel
    public let message: String
    public let timestamp: Date

    public init(level: LogLevel, message: String, timestamp: Date = .init()) {
        self.id = UUID()
        self.level = level
        self.message = message
        self.timestamp = timestamp
    }

    /// Convenience initializer for the gomobile bridge: `timestampNs` is
    /// the Unix-nanoseconds value stamped on the extension side when the
    /// observable drained the event. Pass 0 (or anything ≤0) to fall
    /// back to wall-clock — covers older Go cores or unit tests that
    /// synthesize entries.
    public init(rawLevel: Int, message: String, timestampNs: Int64) {
        self.id = UUID()
        self.level = LogLevel(rawValue: rawLevel) ?? .info
        self.message = message
        if timestampNs > 0 {
            self.timestamp = Date(timeIntervalSince1970: TimeInterval(timestampNs) / 1_000_000_000)
        } else {
            self.timestamp = .init()
        }
    }
}
