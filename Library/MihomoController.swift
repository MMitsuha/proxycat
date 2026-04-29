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
    case transport(URLError)
    case decoding(Error)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let status, let body):
            return "Controller returned HTTP \(status): \(body.prefix(160))"
        case .transport(let err):
            return err.localizedDescription
        case .decoding(let err):
            return "Could not decode controller response: \(err.localizedDescription)"
        case .invalidResponse:
            return "Controller returned a non-HTTP response"
        }
    }
}

// MARK: - Client

/// Talks to mihomo's external-controller (default `http://127.0.0.1:9090`).
///
/// The controller is bound to loopback by `libmihomo/binding.go` and its
/// secret is forced empty there too (binding.go:122,125), so the host app
/// reaches it without auth as long as the tunnel is up. See the design
/// spec for the auth-assumption caveat.
public struct MihomoController {
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:9090")!
    public static let defaultTestURL = "http://www.gstatic.com/generate_204"
    public static let defaultTimeoutMs = 5000

    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(baseURL: URL = defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.decoder = JSONDecoder()
    }

    /// `GET /proxies` → `{ "proxies": { name: Proxy } }`.
    public func proxies() async throws -> [String: Proxy] {
        let req = makeRequest(path: "proxies", timeout: 5)
        let data = try await perform(req)
        do {
            return try decoder.decode(ProxiesResponse.self, from: data).proxies
        } catch {
            throw MihomoControllerError.decoding(error)
        }
    }

    /// `PUT /proxies/{group}` body `{"name": <node>}`. 204 on success.
    /// 400 if the group is not a Selector (URLTest/Fallback/LoadBalance).
    public func select(group: String, name: String) async throws {
        var req = makeRequest(path: "proxies/\(escape(group))", timeout: 5)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        _ = try await perform(req)
    }

    /// `GET /group/{name}/delay?url=&timeout=` → `{ name: delay }` map.
    /// We re-fetch `/proxies` after this to pick up updated histories.
    public func groupDelay(
        name: String,
        url: String = defaultTestURL,
        timeoutMs: Int = defaultTimeoutMs
    ) async throws -> [String: Int] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("group/\(escape(name))/delay"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "url", value: url),
            URLQueryItem(name: "timeout", value: String(timeoutMs)),
        ]
        // Give the request a hair more time than the per-node timeout
        // because the server runs them concurrently and still needs to
        // serialize the result.
        var req = URLRequest(url: components.url!)
        req.timeoutInterval = TimeInterval(timeoutMs) / 1000 + 2
        let data = try await perform(req)
        do {
            return try decoder.decode([String: Int].self, from: data)
        } catch {
            throw MihomoControllerError.decoding(error)
        }
    }

    // MARK: - Private

    private func makeRequest(path: String, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.timeoutInterval = timeout
        return req
    }

    /// Percent-encode a path segment. mihomo's `parseProxyName` middleware
    /// uses `getEscapeParam`, which round-trips a URL-encoded segment.
    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MihomoControllerError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw MihomoControllerError.requestFailed(status: http.statusCode, body: body)
            }
            return data
        } catch let err as MihomoControllerError {
            throw err
        } catch let err as URLError {
            throw MihomoControllerError.transport(err)
        }
    }
}
