import Foundation

public struct HeadroomSnapshot: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case passiveObservations
        case fleetLimits
        case unavailable
    }

    public var serverID: UUID
    public var serverName: String
    public var isDemo: Bool
    public var generatedAt: Date
    public var source: Source
    public var providers: [ProviderHeadroom]

    public init(serverID: UUID, serverName: String, isDemo: Bool, generatedAt: Date, source: Source, providers: [ProviderHeadroom]) {
        self.serverID = serverID
        self.serverName = serverName
        self.isDemo = isDemo
        self.generatedAt = generatedAt
        self.source = source
        self.providers = providers
    }

    public var lowestHeadroom: ProviderHeadroom? {
        providers.filter { $0.headroomPercent != nil }.min { ($0.headroomPercent ?? 0) < ($1.headroomPercent ?? 0) }
    }
}

public enum HeadroomLoader {
    public static func load(profile: ServerProfile, secret: String, transport: any HTTPTransport, now: Date = Date()) async throws -> HeadroomSnapshot {
        switch profile.authMode {
        case .management:
            let client = ManagementClient(baseURL: profile.baseURL, managementKey: secret, transport: transport)
            let credentials = try await client.credentials().value
            let providers = HeadroomCalculator.fromCredentials(credentials.files, now: now)
            return HeadroomSnapshot(serverID: profile.id, serverName: profile.name, isDemo: profile.isDemo, generatedAt: now, source: .passiveObservations, providers: providers)
        case .clientKey:
            let client = ClientKeyClient(baseURL: profile.baseURL, clientKey: secret, transport: transport)
            guard let limits = try await client.fleetLimits() else {
                return HeadroomSnapshot(serverID: profile.id, serverName: profile.name, isDemo: profile.isDemo, generatedAt: now, source: .unavailable, providers: [])
            }
            return HeadroomSnapshot(serverID: profile.id, serverName: profile.name, isDemo: profile.isDemo, generatedAt: now, source: .fleetLimits, providers: HeadroomCalculator.fromFleet(limits))
        }
    }
}
