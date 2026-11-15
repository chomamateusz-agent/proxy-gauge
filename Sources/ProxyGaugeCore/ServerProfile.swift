import Foundation

public enum AuthMode: String, Codable, Sendable, CaseIterable, Hashable {
    case management
    case clientKey
}

public struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: URL
    public var authMode: AuthMode
    public var isDemo: Bool

    public init(id: UUID = UUID(), name: String, baseURL: URL, authMode: AuthMode, isDemo: Bool = false) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.authMode = authMode
        self.isDemo = isDemo
    }

    public static let demoID = UUID(uuidString: "00000000-0000-4000-8000-00000000DE70")!
    public static let demoBaseURL = URL(string: "https://demo.proxygauge.invalid")!

    public static func demo(authMode: AuthMode = .management) -> ServerProfile {
        ServerProfile(id: demoID, name: "Demo server", baseURL: demoBaseURL, authMode: authMode, isDemo: true)
    }

    public func reachesSameData(as other: ServerProfile) -> Bool {
        authMode == other.authMode && ActiveRefreshServer.proxyKey(baseURL) == ActiveRefreshServer.proxyKey(other.baseURL)
    }

    public var usesPlainHTTPOutsideLocalNetwork: Bool {
        guard baseURL.scheme?.lowercased() == "http", let host = baseURL.host()?.lowercased() else { return false }
        return !BaseURLValidator.isLocalHost(host)
    }
}

public enum BaseURLValidator {
    public enum Problem: Error, Equatable, Sendable {
        case empty
        case unsupportedScheme
        case missingHost
        case hasQuery
        case hasUserInfo
    }

    public static func normalize(_ raw: String) -> Result<URL, Problem> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if !text.contains("://") {
            text = defaultScheme(forSchemeless: text) + "://" + text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        guard let components = URLComponents(string: text) else { return .failure(.missingHost) }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failure(.unsupportedScheme)
        }
        guard components.user == nil, components.password == nil else { return .failure(.hasUserInfo) }
        guard let host = components.host, !host.isEmpty else { return .failure(.missingHost) }
        guard components.query == nil, components.fragment == nil else { return .failure(.hasQuery) }
        guard let url = components.url else { return .failure(.missingHost) }
        return .success(url)
    }

    static func defaultScheme(forSchemeless text: String) -> String {
        guard let host = URLComponents(string: "http://" + text)?.host, !host.isEmpty else { return "https" }
        return isLocalHost(host) ? "http" : "https"
    }

    public static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") && !host.contains(":") {
            return true
        }
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fd") || host.hasPrefix("fc")
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }
}
