import Foundation

/// Mihomo log levels: 0=DEBUG 1=INFO 2=WARNING 3=ERROR 4=SILENT.
public enum LogLevel: Int, CaseIterable, Identifiable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case silent = 4

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        case .silent: return "Silent"
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

    /// Convenience initializer for the gomobile bridge which surfaces level
    /// as a raw Int.
    public init(rawLevel: Int, message: String) {
        self.id = UUID()
        self.level = LogLevel(rawValue: rawLevel) ?? .info
        self.message = message
        self.timestamp = .init()
    }
}
