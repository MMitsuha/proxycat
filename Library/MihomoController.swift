import Foundation

// MARK: - Models (mirror mihomo's REST shapes; see hub/route/proxies.go)

public struct ProxyDelayPoint: Codable, Hashable {
    public let time: String
    public let delay: Int
}

public struct Proxy: Codable, Hashable {
    public let name: String
    /// "Selector", "URLTest", "Direct", "Reject", "Fallback", "LoadBalance", ...
    public let type: String
    /// Currently selected child name (groups only).
    public let now: String?
    /// Child names (groups only).
    public let all: [String]?
    public let history: [ProxyDelayPoint]
    public let testUrl: String?
    /// HTTP status range string (e.g. "200" or "200-299"). Optional — only
    /// URLTest/Fallback/LoadBalance emit it; Selector and leaf nodes don't.
    public let expectedStatus: String?
    public let timeout: Int?
    public let hidden: Bool?
    public let udp: Bool?
    public let xudp: Bool?
    public let tfo: Bool?

    /// Last delay sample, or nil if untested. 0 in the JSON means "test failed"
    /// — surfaced as `nil` so the UI shows it as unknown rather than "0 ms".
    public var latestDelay: Int? {
        guard let last = history.last, last.delay > 0 else { return nil }
        return last.delay
    }

    public var isGroup: Bool { all?.isEmpty == false }
    public var isSelector: Bool { type == "Selector" }

    /// Whether `PUT /proxies/{name}` will accept a manual selection. Mirrors
    /// the backend's `outboundgroup.SelectAble` set (Selector, URLTest,
    /// Fallback). LoadBalance and leaf proxies are not selectable.
    public var isSelectable: Bool {
        type == "Selector" || type == "URLTest" || type == "Fallback"
    }
}

public struct ProxiesResponse: Codable {
    public let proxies: [String: Proxy]
}

public struct DelayResponse: Codable {
    public let delay: Int
}

// MARK: - Errors

public enum MihomoControllerError: LocalizedError {
    case requestFailed(status: Int, body: String)
    case transport(Error)
    case encoding(Error)
    case decoding(Error)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let status, let body):
            return "Controller returned HTTP \(status): \(body.prefix(160))"
        case .transport(let err):
            return err.localizedDescription
        case .encoding(let err):
            return "Could not encode controller request: \(err.localizedDescription)"
        case .decoding(let err):
            return "Could not decode controller response: \(err.localizedDescription)"
        case .invalidResponse:
            return "Controller returned a non-HTTP response"
        }
    }
}

// MARK: - Client

/// Talks to mihomo's external-controller through the command IPC channel.
/// The Network Extension still binds mihomo's REST controller to a private
/// App-Group Unix socket, but the host app no longer dials or parses that
/// socket directly. Instead, `CommandClient` forwards these requests over
/// gRPC and the Go side uses the standard `net/http` client against the
/// controller socket. Loopback HTTP (port 9090) still exists for the in-app
/// metacubexd web view, but the host's native UI never touches it.
///
/// `@unchecked Sendable` because JSONDecoder isn't formally Sendable but
/// our instance is configured once at init and used read-only thereafter.
public struct MihomoController: @unchecked Sendable {
    /// Match `C.DefaultTestURL` in mihomo (constant/adapters.go). Selector
    /// groups whose test URL equals the default omit `testUrl` from their
    /// JSON (adapter/outboundgroup/selector.go), so a nil `Proxy.testUrl`
    /// means "use mihomo's default" — falling back to `http` here would
    /// quietly probe a different scheme than the configured/default.
    public static let defaultTestURL = "https://www.gstatic.com/generate_204"
    public static let defaultTimeoutMs = 5000

    public let transport: any ControllerTransport
    private let decoder: JSONDecoder

    @MainActor
    public init() {
        self.init(transport: UnavailableControllerTransport.shared)
    }

    @MainActor
    public init(transport: any ControllerTransport) {
        self.transport = transport
        self.decoder = JSONDecoder()
    }

    /// `GET /proxies` → `{ "proxies": { name: Proxy } }`.
    @MainActor
    public func proxies() async throws(MihomoControllerError) -> [String: Proxy] {
        let data = try await perform(method: "GET", path: Self.makePath("proxies"), timeout: 5)
        do {
            return try decoder.decode(ProxiesResponse.self, from: data).proxies
        } catch {
            throw MihomoControllerError.decoding(error)
        }
    }

    /// `PUT /proxies/{group}` body `{"name": <node>}`. 204 on success.
    /// 400 if the group is not a Selector (URLTest/Fallback/LoadBalance).
    @MainActor
    public func select(group: String, name: String) async throws(MihomoControllerError) {
        let body: Data
        do {
            body = try JSONEncoder().encode(ProxySelectionRequest(name: name))
        } catch {
            throw MihomoControllerError.encoding(error)
        }
        let path = Self.makePath("proxies/\(Self.percentEncodeSegment(group))")
        _ = try await perform(
            method: "PUT",
            path: path,
            headers: [("Content-Type", "application/json")],
            body: body,
            timeout: 5
        )
    }

    /// `GET /group/{name}/delay?url=&timeout=&expected=` → `{ name: delay }`
    /// map. We re-fetch `/proxies` after this to pick up updated histories.
    /// `url`/`timeoutMs` fall back to `defaultTestURL`/`defaultTimeoutMs`
    /// when nil so callers can pass through the group's own settings
    /// straight from the `/proxies` response (testUrl/timeout are optional
    /// in mihomo's marshaller — Selector omits them when at the default).
    @MainActor
    public func groupDelay(
        name: String,
        url: String? = nil,
        timeoutMs: Int? = nil,
        expectedStatus: String? = nil
    ) async throws(MihomoControllerError) -> [String: Int] {
        let resolvedURL: String
        if let url, !url.isEmpty {
            resolvedURL = url
        } else {
            resolvedURL = Self.defaultTestURL
        }
        let resolvedTimeout = timeoutMs ?? Self.defaultTimeoutMs
        var queryItems = [
            URLQueryItem(name: "url", value: resolvedURL),
            URLQueryItem(name: "timeout", value: String(resolvedTimeout)),
        ]
        if let expectedStatus, !expectedStatus.isEmpty {
            queryItems.append(URLQueryItem(name: "expected", value: expectedStatus))
        }
        let path = Self.makePath(
            "group/\(Self.percentEncodeSegment(name))/delay",
            queryItems: queryItems
        )
        // Give the request a hair more time than the per-node timeout
        // because the server runs them concurrently and still needs to
        // serialize the result.
        let timeout = TimeInterval(resolvedTimeout) / 1000 + 2
        let data = try await perform(method: "GET", path: path, timeout: timeout)
        do {
            return try decoder.decode([String: Int].self, from: data)
        } catch {
            throw MihomoControllerError.decoding(error)
        }
    }

    // MARK: - Path helpers

    /// Builds a `/path[?query]` string for the HTTP request-target.
    /// Caller is responsible for percent-encoding any path segment that
    /// may contain reserved characters (use `percentEncodeSegment`).
    /// Query items are encoded by URLComponents.
    public static func makePath(_ path: String, queryItems: [URLQueryItem] = []) -> String {
        var s = "/" + path
        if !queryItems.isEmpty {
            var comps = URLComponents()
            comps.queryItems = queryItems
            if let q = comps.percentEncodedQuery, !q.isEmpty {
                s += "?" + q
            }
        }
        return s
    }

    /// `urlPathAllowed` minus `/`, so a name containing `/`
    /// (e.g. proxy group `JP/Tokyo`) is encoded as one segment instead of two.
    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove("/")
        return set
    }()

    /// Percent-encode a single URL path segment. mihomo's `parseProxyName`
    /// middleware (hub/route/common.go) round-trips the encoding via
    /// `url.PathUnescape`, and chi's `{name}` token doesn't span `/`, so
    /// any `/` inside the name must be `%2F` to land in the right route.
    public static func percentEncodeSegment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? s
    }

    // MARK: - Private

    @MainActor
    private func perform(
        method: String,
        path: String,
        headers: [(String, String)] = [],
        body: Data? = nil,
        timeout: TimeInterval
    ) async throws(MihomoControllerError) -> Data {
        let contentType = headers.first {
            $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.1
        let request = ControllerHTTPRequest(
            method: method,
            path: path,
            contentType: contentType,
            body: body
        )
        let response: ControllerHTTPResponse
        do {
            response = try await transport.sendControllerRequest(request, timeout: timeout)
        } catch {
            throw MihomoControllerError.transport(error)
        }
        guard response.isSuccess else {
            let bodyText = String(data: response.body, encoding: .utf8) ?? ""
            throw MihomoControllerError.requestFailed(status: response.status, body: bodyText)
        }
        return response.body
    }
}

private struct ProxySelectionRequest: Encodable {
    let name: String
}

@MainActor
private final class UnavailableControllerTransport: ControllerTransport {
    static let shared = UnavailableControllerTransport()

    func sendControllerRequest(
        _ request: ControllerHTTPRequest,
        timeout: TimeInterval
    ) async throws -> ControllerHTTPResponse {
        throw ControllerIPCError.notConnected
    }
}
