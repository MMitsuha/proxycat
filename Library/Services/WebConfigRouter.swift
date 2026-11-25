import Foundation

/// HTTP routing for the web editor. Kept separate from `WebConfigServer`
/// so socket lifecycle and request handling can evolve independently.
@MainActor
final class WebConfigRouter {
    func respond(to request: WebConfigHTTPRequest, token: String?) async -> WebConfigHTTPResponse {
        if let staticResponse = staticResponse(for: request) {
            return staticResponse
        }

        guard authorized(request, token: token) else {
            return .jsonError("Unauthorized", status: 401)
        }

        if request.path == "/api/default-profile" {
            guard request.method == "GET" else {
                return .empty(status: 405)
            }
            return .json(DefaultProfileResponse(yaml: BundledAssets.defaultProfileYAML ?? ""))
        }

        if request.path == "/api/profiles" {
            switch request.method {
            case "GET":
                return .json(profileSummaries())
            case "POST":
                return await createProfile(request)
            default:
                return .empty(status: 405)
            }
        }

        if request.path.hasPrefix("/api/profiles/") {
            let rest = request.path.dropFirst("/api/profiles/".count)
            let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard let id = parts.first, !id.isEmpty else {
                return .jsonError("Missing profile id", status: 400)
            }
            guard let profile = profile(withID: id) else {
                return .jsonError("Profile not found", status: 404)
            }

            if parts.count == 1 {
                switch request.method {
                case "GET":
                    do {
                        let yaml = try await ProfileStore.readYAML(of: profile)
                        return .json(ProfileDetail(id: profile.id.uuidString, name: profile.name, yaml: yaml))
                    } catch {
                        return .jsonError(error.localizedDescription, status: 500)
                    }
                case "PUT":
                    return await updateProfile(profile, request: request)
                case "DELETE":
                    do {
                        try ProfileStore.shared.delete(profile)
                        return .empty(status: 204)
                    } catch {
                        return .jsonError(error.localizedDescription, status: 500)
                    }
                default:
                    return .empty(status: 405)
                }
            }

            if parts.count == 2, parts[1] == "activate" {
                guard request.method == "POST" else {
                    return .empty(status: 405)
                }
                ProfileStore.shared.setActive(profile)
                return .json(profileSummary(profile))
            }
        }

        return .jsonError("Not found", status: 404)
    }

    // MARK: - Static assets

    private func staticResponse(for request: WebConfigHTTPRequest) -> WebConfigHTTPResponse? {
        let path = request.path
        guard path == "/" || path == "/index.html" || path == "/app.css"
            || path == "/app.js" || path == "/favicon.ico"
        else { return nil }

        guard request.method == "GET" else {
            return .empty(status: 405)
        }

        switch path {
        case "/", "/index.html":
            guard let html = BundledAssets.webEditorHTML else {
                return .jsonError("Web editor resource is missing", status: 500)
            }
            return .html(html)
        case "/app.css":
            guard let css = BundledAssets.webEditorCSS else {
                return .jsonError("Web editor stylesheet is missing", status: 500)
            }
            return .css(css)
        case "/app.js":
            guard let js = BundledAssets.webEditorJS else {
                return .jsonError("Web editor script is missing", status: 500)
            }
            return .javascript(js)
        case "/favicon.ico":
            return .empty(status: 204)
        default:
            return nil
        }
    }

    // MARK: - API handlers

    private func createProfile(_ request: WebConfigHTTPRequest) async -> WebConfigHTTPResponse {
        guard let body = try? JSONDecoder().decode(ProfileCreateRequest.self, from: request.body) else {
            return .jsonError("Invalid JSON body", status: 400)
        }
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .jsonError("Profile name cannot be empty", status: 400)
        }
        do {
            let profile = try await ProfileStore.shared.importYAML(body.yaml, name: name)
            return .json(profileSummary(profile), status: 201)
        } catch {
            return .jsonError(error.localizedDescription, status: Self.status(for: error))
        }
    }

    private func updateProfile(
        _ profile: Profile,
        request: WebConfigHTTPRequest
    ) async -> WebConfigHTTPResponse {
        guard let body = try? JSONDecoder().decode(ProfileUpdateRequest.self, from: request.body) else {
            return .jsonError("Invalid JSON body", status: 400)
        }
        do {
            try await ProfileStore.shared.updateContent(
                of: profile,
                yaml: body.yaml,
                name: body.name
            )
            let updated = ProfileStore.shared.profiles.first(where: { $0.id == profile.id }) ?? profile
            return .json(profileSummary(updated))
        } catch {
            return .jsonError(error.localizedDescription, status: Self.status(for: error))
        }
    }

    /// Invalid YAML and other caller mistakes are 400s; storage failures
    /// (disk full, index write error) are server errors and must stay
    /// retryable instead of masquerading as a bad request.
    nonisolated static func status(for error: Error) -> Int {
        if error is ProfileValidationError {
            return 400
        }
        if let profileError = error as? ProfileError {
            switch profileError {
            case .profileDeleted:
                return 404
            default:
                return 400
            }
        }
        return 500
    }

    private func profileSummaries() -> [ProfileSummary] {
        let activeID = ProfileStore.shared.activeProfileID
        return ProfileStore.shared.profiles.map { profile in
            ProfileSummary(
                id: profile.id.uuidString,
                name: profile.name,
                isActive: profile.id == activeID,
                hasRemote: profile.remoteURL != nil
            )
        }
    }

    private func profileSummary(_ profile: Profile) -> ProfileSummary {
        ProfileSummary(
            id: profile.id.uuidString,
            name: profile.name,
            isActive: profile.id == ProfileStore.shared.activeProfileID,
            hasRemote: profile.remoteURL != nil
        )
    }

    private func profile(withID id: String) -> Profile? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return ProfileStore.shared.profiles.first { $0.id == uuid }
    }

    private func authorized(_ request: WebConfigHTTPRequest, token: String?) -> Bool {
        guard let token else { return false }
        if let authorization = request.headers["authorization"],
           authorization.hasPrefix("Bearer ") {
            return Self.secureCompare(String(authorization.dropFirst("Bearer ".count)), token)
        }
        if let queryToken = request.query["token"] {
            return Self.secureCompare(queryToken, token)
        }
        return false
    }

    private static func secureCompare(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

// MARK: - Wire types

private struct ProfileSummary: Codable {
    let id: String
    let name: String
    let isActive: Bool
    let hasRemote: Bool
}

private struct ProfileDetail: Codable {
    let id: String
    let name: String
    let yaml: String
}

private struct DefaultProfileResponse: Codable {
    let yaml: String
}

private struct ProfileCreateRequest: Decodable {
    let name: String
    let yaml: String
}

private struct ProfileUpdateRequest: Decodable {
    let name: String?
    let yaml: String
}
