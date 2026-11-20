import Foundation

public enum BridgeAPIError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case unauthorized
    case notFound(String)
    case conflict(String)
    case httpError(statusCode: Int, message: String?)
    case decodingFailed(String)
    case networkError(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let detail):
            return "Invalid bridge URL: \(detail)"
        case .unauthorized:
            return "Authentication failed. Check your bridge bearer token."
        case .notFound(let detail):
            return "Resource not found: \(detail)"
        case .conflict(let detail):
            return "Conflict: \(detail)"
        case .httpError(let statusCode, let message):
            if let message, !message.isEmpty {
                return "Bridge error (\(statusCode)): \(message)"
            }
            return "Bridge returned HTTP \(statusCode)."
        case .decodingFailed(let detail):
            return "Failed to decode bridge response: \(detail)"
        case .networkError(let detail):
            return "Network error: \(detail)"
        case .invalidResponse:
            return "Received an invalid response from the bridge server."
        }
    }
}

public protocol BridgeAPIClientProtocol: Sendable {
    func ping() async throws -> PingResponse
    func fetchHealth() async throws -> HostHealth
    func fetchSessions(limit: Int) async throws -> SessionsResponse
    func fetchTranscript(sessionId: String, sinceStep: Int, limit: Int, full: Bool) async throws -> TranscriptResponse
    func fetchArtifacts(sessionId: String) async throws -> ArtifactsResponse
    func fetchArtifactContent(sessionId: String, relativePath: String) async throws -> ArtifactContentResponse
    func fetchArtifactBinary(sessionId: String, relativePath: String) async throws -> Data
    func fetchTasks(sessionId: String) async throws -> SessionTasksResponse
    func fetchMediaData(urlPath: String) async throws -> Data
    func fetchBinaryData(urlPath: String) async throws -> Data
    func fetchApprovals() async throws -> ApprovalsResponse
    func submitApprovalDecision(approvalId: String, decision: ApprovalDecision, reason: String?) async throws -> ApprovalRequest
}

public extension BridgeAPIClientProtocol {
    func fetchSessions() async throws -> SessionsResponse {
        try await fetchSessions(limit: 50)
    }

    func fetchTranscript(sessionId: String) async throws -> TranscriptResponse {
        try await fetchTranscript(sessionId: sessionId, sinceStep: 0, limit: 200, full: false)
    }

    func fetchBinary(path: String) async throws -> Data {
        try await fetchBinaryData(urlPath: path)
    }

    func submitApprovalDecision(
        approvalId: String,
        decision: ApprovalDecision
    ) async throws -> ApprovalRequest {
        try await submitApprovalDecision(approvalId: approvalId, decision: decision, reason: nil)
    }
}

public struct BridgeAPIClient: BridgeAPIClientProtocol, Sendable {
    public let baseURL: URL
    public let token: String
    public let timeoutInterval: TimeInterval
    private let session: URLSession

    private static let pathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()

    public init(
        baseURL: URL,
        token: String,
        session: URLSession = .shared,
        timeoutInterval: TimeInterval = 20
    ) {
        self.baseURL = (try? PairingURI.normalizeBaseURL(baseURL.absoluteString)) ?? baseURL
        self.token = token
        self.session = session
        self.timeoutInterval = timeoutInterval
    }

    // MARK: - REST Endpoints

    public func ping() async throws -> PingResponse {
        let url = try buildURL(pathSegments: ["api", "v1", "ping"])
        return try await performJSONRequest(url: url, method: "GET", authenticated: false)
    }

    public func fetchHealth() async throws -> HostHealth {
        let url = try buildURL(pathSegments: ["api", "v1", "health"])
        return try await performJSONRequest(url: url, method: "GET", authenticated: true)
    }

    public func fetchSessions(limit: Int) async throws -> SessionsResponse {
        let clampedLimit = max(1, limit)
        let url = try buildURL(
            pathSegments: ["api", "v1", "sessions"],
            queryItems: [URLQueryItem(name: "limit", value: String(clampedLimit))]
        )
        return try await performJSONRequest(url: url, method: "GET", authenticated: true)
    }

    public func fetchTranscript(
        sessionId: String,
        sinceStep: Int,
        limit: Int,
        full: Bool
    ) async throws -> TranscriptResponse {
        let url = try buildURL(
            pathSegments: ["api", "v1", "sessions", sessionId, "transcript"],
            queryItems: [
                URLQueryItem(name: "since_step", value: String(max(0, sinceStep))),
                URLQueryItem(name: "limit", value: String(max(1, limit))),
                URLQueryItem(name: "full", value: full ? "true" : "false")
            ]
        )
        return try await performJSONRequest(url: url, method: "GET", authenticated: true)
    }

    public func fetchArtifacts(sessionId: String) async throws -> ArtifactsResponse {
        let url = try buildURL(pathSegments: ["api", "v1", "sessions", sessionId, "artifacts"])
        return try await performJSONRequest(url: url, method: "GET", authenticated: true)
    }

    public func fetchArtifactContent(
        sessionId: String,
        relativePath: String
    ) async throws -> ArtifactContentResponse {
        let pathSegments = ["api", "v1", "sessions", sessionId, "artifacts"] + splitRelativePath(relativePath)
        let url = try buildURL(
            pathSegments: pathSegments,
            queryItems: [URLQueryItem(name: "format", value: "json")]
        )
        return try await performJSONRequest(url: url, method: "GET", authenticated: true)
    }

    public func fetchArtifactBinary(
        sessionId: String,
        relativePath: String
    ) async throws -> Data {
        let pathSegments = ["api", "v1", "sessions", sessionId, "artifacts"] + splitRelativePath(relativePath)
        let url = try buildURL(pathSegments: pathSegments)
        return try await performDataRequest(url: url, method: "GET", authenticated: true, accept: "*/*")
    }

    public func fetchTasks(sessionId: String) async throws -> SessionTasksResponse {
        let url = try buildURL(pathSegments: ["api", "v1", "sessions", sessionId, "tasks"])
        return try await performJSONRequest(url: url, method: "GET", authenticated: true)
    }

    public func fetchMediaData(urlPath: String) async throws -> Data {
        try await fetchBinaryData(urlPath: urlPath)
    }

    public func fetchMediaData(sessionId: String, filename: String) async throws -> Data {
        let url = try buildURL(pathSegments: ["api", "v1", "sessions", sessionId, "media", filename])
        return try await performDataRequest(url: url, method: "GET", authenticated: true, accept: "*/*")
    }

    public func fetchBinaryData(urlPath: String) async throws -> Data {
        let url = try resolveURL(for: urlPath)
        return try await performDataRequest(url: url, method: "GET", authenticated: true, accept: "*/*")
    }

    public func fetchApprovals() async throws -> ApprovalsResponse {
        let url = try buildURL(pathSegments: ["api", "v1", "approvals"])
        return try await performJSONRequest(url: url, method: "GET", authenticated: true)
    }

    public func submitApprovalDecision(
        approvalId: String,
        decision: ApprovalDecision,
        reason: String?
    ) async throws -> ApprovalRequest {
        let url = try buildURL(pathSegments: ["api", "v1", "approvals", approvalId, "decide"])
        let payload = ApprovalDecisionPayload(decision: decision, reason: reason)
        let body: Data
        do {
            body = try BridgeJSONEncoder.encode(payload)
        } catch {
            throw BridgeAPIError.decodingFailed("Failed to encode approval decision: \(error.localizedDescription)")
        }
        return try await performJSONRequest(url: url, method: "POST", body: body, authenticated: true)
    }

    // MARK: - URL Construction

    private func splitRelativePath(_ relativePath: String) -> [String] {
        relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func buildURL(pathSegments: [String], queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw BridgeAPIError.invalidURL(baseURL.absoluteString)
        }

        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }

        let encodedSegments = try pathSegments.map { segment -> String in
            guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) else {
                throw BridgeAPIError.invalidURL(segment)
            }
            return encoded
        }

        components.percentEncodedPath = basePath + "/" + encodedSegments.joined(separator: "/")
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        } else {
            components.queryItems = nil
        }

        guard let url = components.url else {
            throw BridgeAPIError.invalidURL(components.percentEncodedPath)
        }
        return url
    }

    private func resolveURL(for urlPath: String) throws -> URL {
        let trimmed = urlPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BridgeAPIError.invalidURL("Empty path")
        }

        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            guard let absolute = URL(string: trimmed) else {
                throw BridgeAPIError.invalidURL(trimmed)
            }
            return absolute
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw BridgeAPIError.invalidURL(baseURL.absoluteString)
        }

        let parts = trimmed.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts[0])
        let rawQuery = parts.count > 1 ? String(parts[1]) : nil

        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }

        let rawSegments = rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let encodedSegments = try rawSegments.map { segment -> String in
            let decoded = segment.removingPercentEncoding ?? segment
            guard let encoded = decoded.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) else {
                throw BridgeAPIError.invalidURL(segment)
            }
            return encoded
        }
        let normalizedRelativePath = "/" + encodedSegments.joined(separator: "/")

        if !basePath.isEmpty && !normalizedRelativePath.hasPrefix(basePath + "/") && normalizedRelativePath != basePath {
            components.percentEncodedPath = basePath + normalizedRelativePath
        } else {
            components.percentEncodedPath = normalizedRelativePath
        }

        if let rawQuery, !rawQuery.isEmpty {
            components.percentEncodedQuery = rawQuery
        } else {
            components.queryItems = nil
        }

        guard let url = components.url else {
            throw BridgeAPIError.invalidURL(trimmed)
        }
        return url
    }

    // MARK: - HTTP Execution

    private func performJSONRequest<Response: Decodable>(
        url: URL,
        method: String,
        body: Data? = nil,
        authenticated: Bool
    ) async throws -> Response {
        let data = try await performDataRequest(
            url: url,
            method: method,
            body: body,
            authenticated: authenticated,
            accept: "application/json"
        )
        do {
            return try BridgeJSONDecoder.decode(Response.self, from: data)
        } catch {
            throw BridgeAPIError.decodingFailed(error.localizedDescription)
        }
    }

    private func performDataRequest(
        url: URL,
        method: String,
        body: Data? = nil,
        authenticated: Bool,
        accept: String
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        request.setValue(accept, forHTTPHeaderField: "Accept")

        if authenticated && !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw BridgeAPIError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BridgeAPIError.invalidResponse
        }

        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw BridgeAPIError.unauthorized
        case 404:
            throw BridgeAPIError.notFound(Self.extractErrorMessage(from: data) ?? url.path)
        case 409:
            throw BridgeAPIError.conflict(Self.extractErrorMessage(from: data) ?? "Conflict")
        default:
            throw BridgeAPIError.httpError(
                statusCode: http.statusCode,
                message: Self.extractErrorMessage(from: data)
            )
        }
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error", "detail", "message"] {
                if let value = json[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return String(text.prefix(240))
        }
        return nil
    }
}
