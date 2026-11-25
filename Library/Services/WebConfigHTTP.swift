import Foundation
@preconcurrency import Network

enum WebConfigHTTPError: Error {
    case badRequest(String)
    case tooLarge
}

struct WebConfigHTTPRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

struct WebConfigHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> Self {
        do {
            let data = try JSONEncoder().encode(value)
            return Self(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: data
            )
        } catch {
            return Self.jsonError("Could not encode response", status: 500)
        }
    }

    static func jsonError(_ message: String, status: Int) -> Self {
        let body = (try? JSONEncoder().encode(["error": message])) ?? Data()
        return Self(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }

    static func html(_ text: String) -> Self {
        Self(
            status: 200,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Security-Policy": "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'",
            ],
            body: Data(text.utf8)
        )
    }

    static func css(_ text: String) -> Self {
        Self(
            status: 200,
            headers: ["Content-Type": "text/css; charset=utf-8"],
            body: Data(text.utf8)
        )
    }

    static func javascript(_ text: String) -> Self {
        Self(
            status: 200,
            headers: ["Content-Type": "text/javascript; charset=utf-8"],
            body: Data(text.utf8)
        )
    }

    static func empty(status: Int) -> Self {
        Self(status: status, headers: [:], body: Data())
    }

    var serialized: Data {
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"
        allHeaders["Cache-Control"] = "no-store"
        allHeaders["Referrer-Policy"] = "no-referrer"
        allHeaders["X-Content-Type-Options"] = "nosniff"
        let head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
            + allHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
            + "\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Response"
        }
    }
}

enum WebConfigHTTP {
    static func readRequest(from connection: NWConnection) async throws -> WebConfigHTTPRequest {
        let headerLimit = 64 * 1024
        var buffer = Data()
        var headerEnd: Range<Data.Index>?

        while headerEnd == nil {
            guard buffer.count <= headerLimit else {
                throw WebConfigHTTPError.tooLarge
            }
            let chunk = try await receive(from: connection, maximum: 32 * 1024)
            guard !chunk.isEmpty else {
                throw WebConfigHTTPError.badRequest("Connection closed before headers")
            }
            buffer.append(chunk)
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
        }

        guard let headerEnd else {
            throw WebConfigHTTPError.badRequest("Malformed request")
        }
        guard let headerText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            throw WebConfigHTTPError.badRequest("Headers are not UTF-8")
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw WebConfigHTTPError.badRequest("Missing request line")
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw WebConfigHTTPError.badRequest("Malformed request line")
        }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = value
        }

        let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
        guard bodyLength >= 0, bodyLength <= WebConfigHTTPServerLimits.maxBodyBytes else {
            throw WebConfigHTTPError.tooLarge
        }

        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < bodyLength {
            let chunk = try await receive(
                from: connection,
                maximum: min(64 * 1024, bodyLength - body.count)
            )
            guard !chunk.isEmpty else {
                throw WebConfigHTTPError.badRequest("Connection closed before body")
            }
            body.append(chunk)
        }
        if body.count > bodyLength {
            body = body.prefix(bodyLength)
        }

        let targetString = target.hasPrefix("http://") || target.hasPrefix("https://")
            ? target
            : "http://localhost\(target)"
        guard let components = URLComponents(string: targetString) else {
            throw WebConfigHTTPError.badRequest("Malformed request target")
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let path = components.path.isEmpty ? "/" : components.path
        return WebConfigHTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body
        )
    }

    static func send(_ response: WebConfigHTTPResponse, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: response.serialized,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private static func receive(from connection: NWConnection, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

enum WebConfigHTTPServerLimits {
    static let maxBodyBytes = 2 * 1024 * 1024
}
