import Foundation

@MainActor
public protocol ControllerTransport: AnyObject {
    func sendControllerRequest(
        _ request: ControllerHTTPRequest,
        timeout: TimeInterval
    ) async throws -> ControllerHTTPResponse
}

/// A single native-controller request. `path` is the absolute request target
/// sent to mihomo's REST router, including any already-percent-encoded path
/// segments and optional query string.
public struct ControllerHTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var contentType: String?
    public var body: Data?

    public init(
        method: String,
        path: String,
        contentType: String? = nil,
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.contentType = contentType
        self.body = body
    }
}

/// HTTP status and body returned by mihomo's controller. Headers are
/// intentionally not part of the Swift contract because the native UI only
/// consumes JSON bodies and 2xx/non-2xx status.
public struct ControllerHTTPResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public var isSuccess: Bool { (200 ..< 300).contains(status) }
}

public enum ControllerIPCError: LocalizedError {
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Command IPC is not connected"
        }
    }
}
