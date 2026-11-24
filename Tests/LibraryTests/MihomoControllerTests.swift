import Foundation
import Testing
@testable import Library

@Suite struct MihomoControllerTests {
    @Test func percentEncodeSegmentEscapesSlash() {
        #expect(MihomoController.percentEncodeSegment("JP/Tokyo") == "JP%2FTokyo")
        #expect(MihomoController.percentEncodeSegment("a/b/c") == "a%2Fb%2Fc")
    }

    @Test func percentEncodeSegmentLeavesUnreservedAlone() {
        #expect(MihomoController.percentEncodeSegment("Direct") == "Direct")
        #expect(MihomoController.percentEncodeSegment("US-West.1") == "US-West.1")
    }

    @Test func percentEncodeSegmentEscapesQueryAndFragment() {
        #expect(MihomoController.percentEncodeSegment("a?b") == "a%3Fb")
        #expect(MihomoController.percentEncodeSegment("a#b") == "a%23b")
        #expect(MihomoController.percentEncodeSegment("a b") == "a%20b")
    }

    /// A slash inside a proxy group name is encoded as `%2F` and survives
    /// path assembly as one segment, so chi's `{name}` route matches it
    /// and `url.PathUnescape` round-trips it back to `JP/Tokyo` server-side.
    @Test func makePathPreservesEscapedSlashInPath() {
        let segment = MihomoController.percentEncodeSegment("JP/Tokyo")
        let path = MihomoController.makePath("proxies/\(segment)")
        #expect(path == "/proxies/JP%2FTokyo")
    }

    @Test func makePathAppendsQueryItems() {
        let segment = MihomoController.percentEncodeSegment("JP/Tokyo")
        let path = MihomoController.makePath(
            "group/\(segment)/delay",
            queryItems: [
                URLQueryItem(name: "url", value: "https://www.gstatic.com/generate_204"),
                URLQueryItem(name: "timeout", value: "5000"),
            ]
        )
        #expect(path.hasPrefix("/group/JP%2FTokyo/delay?"))
        #expect(path.contains("timeout=5000"))
        #expect(path.contains("url=https"))
    }

    @Test func makePathOmitsQueryWhenEmpty() {
        let path = MihomoController.makePath("proxies")
        #expect(path == "/proxies")
    }

    @Test func makePathEncodesConnectionId() {
        let id = "abc/def"  // synthetic — real mihomo IDs are UUIDs
        let path = MihomoController.makePath(
            "connections/\(MihomoController.percentEncodeSegment(id))"
        )
        #expect(path == "/connections/abc%2Fdef")
    }
}

@MainActor
@Suite struct MihomoControllerConnectionsTests {
    @MainActor
    private final class RecordingTransport: ControllerTransport {
        private(set) var requests: [ControllerHTTPRequest] = []
        private let response: ControllerHTTPResponse

        init(response: ControllerHTTPResponse) {
            self.response = response
        }

        func sendControllerRequest(
            _ request: ControllerHTTPRequest,
            timeout _: TimeInterval
        ) async throws -> ControllerHTTPResponse {
            requests.append(request)
            return response
        }
    }

    private static let snapshotJSON = """
    {
      "downloadTotal": 4096,
      "uploadTotal": 1024,
      "connections": [
        {
          "id": "abc-123",
          "metadata": {
            "network": "tcp",
            "type": "HTTP",
            "sourceIP": "192.0.2.10",
            "destinationIP": "198.51.100.7",
            "sourcePort": "54321",
            "destinationPort": "443",
            "host": "example.com",
            "process": "Safari",
            "processPath": "/Applications/Safari"
          },
          "upload": 10,
          "download": 20,
          "start": "2026-05-11T14:00:00.123Z",
          "chains": ["Proxy", "DIRECT"],
          "rule": "DomainSuffix",
          "rulePayload": "example.com"
        }
      ],
      "memory": 0
    }
    """.data(using: .utf8)!

    @Test func connectionsDecodesSnapshotAndDate() async throws {
        let transport = RecordingTransport(
            response: ControllerHTTPResponse(status: 200, body: Self.snapshotJSON)
        )
        let controller = MihomoController(transport: transport)

        let snapshot = try await controller.connections()

        #expect(transport.requests.count == 1)
        #expect(transport.requests.first?.method == "GET")
        #expect(transport.requests.first?.path == "/connections?interval=1000")
        #expect(snapshot.uploadTotal == 1024)
        #expect(snapshot.downloadTotal == 4096)

        let connection = try #require(snapshot.connections?.first)
        #expect(connection.metadata.host == "example.com")
        #expect(connection.chains == ["Proxy", "DIRECT"])
        #expect(connection.rule == "DomainSuffix")
        #expect(connection.uploadSpeed == 0)
        #expect(connection.downloadSpeed == 0)
        #expect(connection.start.timeIntervalSince1970 > 0)
    }

    @Test func closeConnectionEncodesIDAsOnePathSegment() async throws {
        let transport = RecordingTransport(
            response: ControllerHTTPResponse(status: 204, body: Data())
        )
        let controller = MihomoController(transport: transport)

        try await controller.closeConnection(id: "abc/def")

        #expect(transport.requests.first?.method == "DELETE")
        #expect(transport.requests.first?.path == "/connections/abc%2Fdef")
    }

    @Test func closeAllConnectionsUsesCollectionPath() async throws {
        let transport = RecordingTransport(
            response: ControllerHTTPResponse(status: 204, body: Data())
        )
        let controller = MihomoController(transport: transport)

        try await controller.closeAllConnections()

        #expect(transport.requests.first?.method == "DELETE")
        #expect(transport.requests.first?.path == "/connections")
    }

    @Test func connectionsSurfacesHTTPFailure() async throws {
        let transport = RecordingTransport(
            response: ControllerHTTPResponse(status: 503, body: Data("unavailable".utf8))
        )
        let controller = MihomoController(transport: transport)

        do {
            _ = try await controller.connections()
            Issue.record("Expected requestFailed")
        } catch {
            guard case let .requestFailed(status, body) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(status == 503)
            #expect(body == "unavailable")
        }
    }

    @Test func connectionsSurfacesDecodeFailure() async throws {
        let transport = RecordingTransport(
            response: ControllerHTTPResponse(status: 200, body: Data("not-json".utf8))
        )
        let controller = MihomoController(transport: transport)

        do {
            _ = try await controller.connections()
            Issue.record("Expected decoding error")
        } catch {
            guard case .decoding = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }
}
