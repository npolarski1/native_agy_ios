import Foundation

public struct HostProfile: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var baseURL: URL
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: URL,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    public var displayHost: String {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host else {
            return baseURL.absoluteString
        }
        if let port = components.port {
            return "\(host):\(port)"
        }
        return host
    }

    public var normalizedBaseURLKey: String {
        if let normalized = try? PairingURI.normalizeBaseURL(baseURL.absoluteString) {
            return normalized.absoluteString.lowercased()
        }
        return baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    public func websocketURL(token: String? = nil) -> URL? {
        try? BridgeWebSocketClient.webSocketURL(from: baseURL, token: token)
    }
}

public struct PairingPayload: Hashable, Sendable {
    public let baseURL: URL
    public let token: String
    public let name: String

    public init(baseURL: URL, token: String, name: String) {
        self.baseURL = baseURL
        self.token = token
        self.name = name
    }
}

public enum PairingURIError: Error, LocalizedError, Equatable, Sendable {
    case invalidURI
    case unsupportedScheme(String)
    case unsupportedAction(String)
    case missingURL
    case invalidBaseURL(String)
    case unsupportedBaseURLScheme(String)
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .invalidURI:
            return "The pairing link is not a valid URI."
        case .unsupportedScheme(let scheme):
            return "Unsupported pairing URI scheme '\(scheme)'. Expected 'agymon://'."
        case .unsupportedAction(let action):
            return "Unsupported pairing action '\(action)'. Expected 'pair'."
        case .missingURL:
            return "The pairing link is missing the bridge 'url' parameter."
        case .invalidBaseURL(let raw):
            return "Invalid bridge URL: '\(raw)'."
        case .unsupportedBaseURLScheme(let scheme):
            return "Bridge URL scheme '\(scheme)' is not supported. Use http or https."
        case .missingToken:
            return "The pairing link is missing the authentication 'token' parameter."
        }
    }
}

public enum PairingURI {
    public static let scheme = "agymon"
    public static let pairHost = "pair"

    public static func parse(_ rawString: String) throws -> PairingPayload {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed) else {
            throw PairingURIError.invalidURI
        }
        return try parse(components: components)
    }

    public static func parse(_ url: URL) throws -> PairingPayload {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PairingURIError.invalidURI
        }
        return try parse(components: components)
    }

    public static func normalizeBaseURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PairingURIError.invalidBaseURL(raw)
        }

        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else if shouldPrependHTTP(to: trimmed) {
            candidate = "http://\(trimmed)"
        } else {
            candidate = trimmed
        }

        guard var components = URLComponents(string: candidate) else {
            throw PairingURIError.invalidBaseURL(raw)
        }

        guard let rawScheme = components.scheme, !rawScheme.isEmpty else {
            throw PairingURIError.invalidBaseURL(raw)
        }
        let lowerScheme = rawScheme.lowercased()
        guard lowerScheme == "http" || lowerScheme == "https" else {
            throw PairingURIError.unsupportedBaseURLScheme(rawScheme)
        }
        guard let rawHost = components.host, !rawHost.isEmpty else {
            throw PairingURIError.invalidBaseURL(raw)
        }

        components.scheme = lowerScheme
        components.host = rawHost.lowercased()
        components.query = nil
        components.fragment = nil

        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path

        guard let normalized = components.url else {
            throw PairingURIError.invalidBaseURL(raw)
        }
        return normalized
    }

    public static func buildURI(baseURL: URL, token: String, name: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = pairHost

        let normalized = (try? normalizeBaseURL(baseURL.absoluteString)) ?? baseURL
        var items: [URLQueryItem] = [
            URLQueryItem(name: "url", value: normalized.absoluteString),
            URLQueryItem(name: "token", value: token)
        ]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            items.append(URLQueryItem(name: "name", value: name))
        }
        components.queryItems = items
        return components.url
    }

    // MARK: - Private

    private static func parse(components: URLComponents) throws -> PairingPayload {
        guard let rawScheme = components.scheme, !rawScheme.isEmpty else {
            throw PairingURIError.invalidURI
        }
        guard rawScheme.lowercased() == scheme else {
            throw PairingURIError.unsupportedScheme(rawScheme)
        }

        let action = (components.host ?? "").isEmpty
            ? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : (components.host ?? "")
        guard action.lowercased() == pairHost else {
            throw PairingURIError.unsupportedAction(action)
        }

        let queryItems = components.queryItems ?? []
        func queryValue(named key: String) -> String? {
            queryItems.first(where: { $0.name.lowercased() == key })?.value
        }

        guard let rawURL = queryValue(named: "url")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            throw PairingURIError.missingURL
        }
        let baseURL = try normalizeBaseURL(rawURL)

        guard let token = queryValue(named: "token")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw PairingURIError.missingToken
        }

        let rawName = queryValue(named: "name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if let rawName, !rawName.isEmpty {
            resolvedName = rawName
        } else {
            resolvedName = baseURL.host ?? "Antigravity Host"
        }

        return PairingPayload(baseURL: baseURL, token: token, name: resolvedName)
    }

    private static func shouldPrependHTTP(to value: String) -> Bool {
        if value.hasPrefix("[") {
            return true
        }
        let authorityPart = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        guard let colonIndex = authorityPart.firstIndex(of: ":") else {
            return true
        }
        let afterColon = authorityPart[authorityPart.index(after: colonIndex)...]
        guard !afterColon.isEmpty else {
            return false
        }
        return afterColon.allSatisfy { $0.isNumber }
    }
}
