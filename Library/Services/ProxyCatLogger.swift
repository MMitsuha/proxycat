import Foundation
import os

public final class ProxyCatLogger: @unchecked Sendable {
    private let logger: Logger
    private let category: String

    public init(subsystem: String, category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        ProxyCatLogPersistence.shared.append(level: "DEBUG", category: category, message: message)
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        ProxyCatLogPersistence.shared.append(level: "INFO", category: category, message: message)
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        ProxyCatLogPersistence.shared.append(level: "WARN", category: category, message: message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        ProxyCatLogPersistence.shared.append(level: "ERROR", category: category, message: message)
    }
}
