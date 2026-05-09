import Darwin
import Foundation

/// Minimal HTTP/1.1 client over a Unix-domain socket. Used by
/// `MihomoController` and `ConnectionsStore` to talk to mihomo's REST
/// controller on its App-Group socket without going through the
/// loopback HTTP listener.
///
/// Each `send` opens a fresh connection, writes the request, reads the
/// response to EOF (we always set `Connection: close`), and parses
/// status / headers / body. Decodes `Transfer-Encoding: chunked` —
/// Go's net/http picks chunked for any response larger than its
/// internal write buffer, which the `/proxies` and `/connections`
/// snapshots reach routinely.
///
/// Single-shot connections only; no pooling. Unix-socket dial cost on
/// loopback is microseconds, well below the per-poll work mihomo does
/// to compute the snapshots themselves.
public struct UnixHTTPClient: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Issue a request and return the full response. Throws
    /// `UnixHTTPError` on socket / parse failures and on timeout.
    public func send(_ request: UnixHTTPRequest, timeout: TimeInterval = 5) async throws -> UnixHTTPResponse {
        let path = socketPath
        return try await Task.detached(priority: .userInitiated) {
            try Self.perform(request: request, socketPath: path, timeout: timeout)
        }.value
    }

    // MARK: - Blocking implementation

    private static func perform(
        request: UnixHTTPRequest,
        socketPath: String,
        timeout: TimeInterval
    ) throws -> UnixHTTPResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixHTTPError.socketCreate(errno: errno) }
        defer { close(fd) }

        try applyTimeouts(fd: fd, timeout: timeout)
        try connect(fd: fd, path: socketPath)
        try write(fd: fd, head: buildRequestHead(request), body: request.body)
        let raw = try readToEOF(fd: fd)
        return try parseResponse(raw)
    }

    private static func applyTimeouts(fd: Int32, timeout: TimeInterval) throws {
        // Clamp: a non-positive timeout disables the SO_*TIMEO knob (treats
        // as "blocking forever"), which would let a wedged extension hang
        // a UI poll indefinitely. 100ms minimum is well above any honest
        // round trip on a Unix socket.
        let clamped = max(timeout, 0.1)
        var tv = timeval(
            tv_sec: Int(clamped),
            tv_usec: Int32((clamped - floor(clamped)) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size) != 0 {
            throw UnixHTTPError.setsockopt(errno: errno)
        }
        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size) != 0 {
            throw UnixHTTPError.setsockopt(errno: errno)
        }
    }

    private static func connect(fd: Int32, path: String) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        let copied: Int = withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            path.withCString { cstr in
                let len = Int(strlen(cstr))
                let n = min(len, pathSize - 1)
                memcpy(buffer.baseAddress!, cstr, n)
                buffer.bindMemory(to: CChar.self)[n] = 0
                return n
            }
        }
        if copied >= pathSize {
            throw UnixHTTPError.connect(errno: ENAMETOOLONG, path: path)
        }
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result < 0 {
            throw UnixHTTPError.connect(errno: errno, path: path)
        }
    }

    private static func write(fd: Int32, head: Data, body: Data?) throws {
        try writeAll(fd: fd, data: head)
        if let body, !body.isEmpty {
            try writeAll(fd: fd, data: body)
        }
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = Darwin.write(fd, base.advanced(by: offset), total - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw UnixHTTPError.timedOut
                    }
                    throw UnixHTTPError.write(errno: errno)
                } else {
                    throw UnixHTTPError.write(errno: 0)
                }
            }
        }
    }

    private static func readToEOF(fd: Int32) throws -> Data {
        var data = Data()
        // 16 KB chunks balance syscall overhead against memory churn for
        // multi-hundred-KB /connections snapshots.
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                recv(fd, ptr.baseAddress, ptr.count, 0)
            }
            if n > 0 {
                data.append(buf, count: n)
            } else if n == 0 {
                return data
            } else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw UnixHTTPError.timedOut
                }
                throw UnixHTTPError.read(errno: errno)
            }
        }
    }

    // MARK: - Request encoding

    private static func buildRequestHead(_ req: UnixHTTPRequest) -> Data {
        var s = "\(req.method) \(req.path) HTTP/1.1\r\n"
        // mihomo's chi router doesn't validate Host; "localhost" is the
        // conventional placeholder for non-IP transports.
        s += "Host: localhost\r\n"
        s += "Connection: close\r\n"
        s += "Accept: */*\r\n"
        var sawContentLength = false
        for (name, value) in req.headers {
            let lower = name.lowercased()
            if lower == "host" || lower == "connection" { continue }
            if lower == "content-length" { sawContentLength = true }
            s += "\(name): \(value)\r\n"
        }
        if let body = req.body, !sawContentLength {
            s += "Content-Length: \(body.count)\r\n"
        }
        s += "\r\n"
        return Data(s.utf8)
    }

    // MARK: - Response parsing

    private static func parseResponse(_ data: Data) throws -> UnixHTTPResponse {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = data.range(of: separator) else {
            throw UnixHTTPError.malformedResponse("no header terminator")
        }
        let headData = data.subdata(in: data.startIndex ..< range.lowerBound)
        var bodyData = data.subdata(in: range.upperBound ..< data.endIndex)
        guard let headStr = String(data: headData, encoding: .utf8) else {
            throw UnixHTTPError.malformedResponse("non-UTF-8 header section")
        }
        var lines = headStr.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            throw UnixHTTPError.malformedResponse("empty header section")
        }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let code = Int(parts[1]) else {
            throw UnixHTTPError.malformedResponse("bad status line: \(statusLine)")
        }
        var headers: [(String, String)] = []
        headers.reserveCapacity(lines.count)
        var transferEncoding: String?
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw UnixHTTPError.malformedResponse("header missing colon: \(line)")
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame {
                transferEncoding = value
            }
            headers.append((name, value))
        }
        if let te = transferEncoding, te.lowercased().contains("chunked") {
            bodyData = try decodeChunked(bodyData)
        }
        return UnixHTTPResponse(status: code, headers: headers, body: bodyData)
    }

    /// Decode `Transfer-Encoding: chunked` per RFC 7230 §4.1. Trailers
    /// (if any) are dropped — no /proxies or /connections endpoint
    /// emits them, and the host doesn't act on them.
    private static func decodeChunked(_ raw: Data) throws -> Data {
        var out = Data()
        var idx = raw.startIndex
        let crlf = Data([0x0D, 0x0A])
        while idx < raw.endIndex {
            guard let term = raw.range(of: crlf, in: idx ..< raw.endIndex) else {
                throw UnixHTTPError.malformedResponse("chunked: missing size CRLF")
            }
            let sizeLineData = raw.subdata(in: idx ..< term.lowerBound)
            // Strip optional `;ext` chunk extension before parsing.
            let sizeBytes: Data
            if let semi = sizeLineData.firstIndex(of: 0x3B /* ; */) {
                sizeBytes = sizeLineData.subdata(in: sizeLineData.startIndex ..< semi)
            } else {
                sizeBytes = sizeLineData
            }
            guard let sizeStr = String(data: sizeBytes, encoding: .ascii) else {
                throw UnixHTTPError.malformedResponse("chunked: non-ASCII size")
            }
            guard let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw UnixHTTPError.malformedResponse("chunked: bad size '\(sizeStr)'")
            }
            idx = term.upperBound
            if size == 0 { return out }
            let chunkEnd = raw.index(idx, offsetBy: size)
            guard chunkEnd <= raw.endIndex else {
                throw UnixHTTPError.malformedResponse("chunked: short chunk")
            }
            out.append(raw.subdata(in: idx ..< chunkEnd))
            idx = chunkEnd
            // Expect CRLF after each chunk's data.
            guard raw.index(idx, offsetBy: 2) <= raw.endIndex,
                  raw[idx] == 0x0D, raw[idx + 1] == 0x0A
            else {
                throw UnixHTTPError.malformedResponse("chunked: missing chunk CRLF")
            }
            idx = raw.index(idx, offsetBy: 2)
        }
        return out
    }
}

public struct UnixHTTPRequest: Sendable {
    public var method: String
    /// Path + query, percent-encoded. The client does not re-encode.
    public var path: String
    public var headers: [(String, String)]
    public var body: Data?

    public init(
        method: String,
        path: String,
        headers: [(String, String)] = [],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct UnixHTTPResponse: Sendable {
    public let status: Int
    public let headers: [(String, String)]
    public let body: Data

    public func headerValue(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    public var isSuccess: Bool { (200 ..< 300).contains(status) }
}

public enum UnixHTTPError: LocalizedError {
    case socketCreate(errno: Int32)
    case setsockopt(errno: Int32)
    case connect(errno: Int32, path: String)
    case write(errno: Int32)
    case read(errno: Int32)
    case timedOut
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .socketCreate(let e):
            return "socket() failed: \(Self.message(for: e))"
        case .setsockopt(let e):
            return "setsockopt() failed: \(Self.message(for: e))"
        case .connect(let e, let path):
            return "connect(\(path)) failed: \(Self.message(for: e))"
        case .write(let e):
            return "write to controller socket failed: \(Self.message(for: e))"
        case .read(let e):
            return "read from controller socket failed: \(Self.message(for: e))"
        case .timedOut:
            return "Controller socket request timed out"
        case .malformedResponse(let msg):
            return "Malformed HTTP response: \(msg)"
        }
    }

    private static func message(for code: Int32) -> String {
        guard let cstr = strerror(code) else { return "errno \(code)" }
        return String(cString: cstr)
    }
}
