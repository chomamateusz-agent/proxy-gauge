import Foundation

public enum DeepLink: Equatable, Sendable {
    case serverOverview(UUID)

    static let serverHost = "server"
    static let overviewPath = "overview"

    public func url(scheme: String) -> URL? {
        switch self {
        case .serverOverview(let id):
            var components = URLComponents()
            components.scheme = scheme
            components.host = Self.serverHost
            components.path = "/\(id.uuidString)/\(Self.overviewPath)"
            return components.url
        }
    }

    public init?(url: URL, scheme: String) {
        guard url.scheme?.lowercased() == scheme.lowercased(), url.host()?.lowercased() == Self.serverHost else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[1].lowercased() == Self.overviewPath, let id = UUID(uuidString: parts[0]) else { return nil }
        self = .serverOverview(id)
    }
}
