import Foundation

/// Fetches subscription YAML from a remote URL.
///
/// Sets a `clash.meta` User-Agent because most subscription providers
/// branch on UA to emit Clash/Mihomo-flavored configs (vs. v2ray, etc.).
public enum RemoteProfileFetcher {
    public static func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("clash.meta", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProfileError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw ProfileError.emptyResponse }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
