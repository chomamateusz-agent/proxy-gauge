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
    public var poolAccounts: [PoolAccount]

    public init(serverID: UUID, serverName: String, isDemo: Bool, generatedAt: Date, source: Source, providers: [ProviderHeadroom], poolAccounts: [PoolAccount] = []) {
        self.serverID = serverID
        self.serverName = serverName
        self.isDemo = isDemo
        self.generatedAt = generatedAt
        self.source = source
        self.providers = providers
        self.poolAccounts = poolAccounts
    }

    public static func management(_ profile: ServerProfile, credentials: [Credential], now: Date) -> HeadroomSnapshot {
        HeadroomSnapshot(
            serverID: profile.id,
            serverName: profile.name,
            isDemo: profile.isDemo,
            generatedAt: now,
            source: .passiveObservations,
            providers: HeadroomCalculator.fromCredentials(credentials, now: now),
            poolAccounts: credentials.map { PoolAccount(credential: $0, now: now) }
        )
    }

    public static func clientKey(_ profile: ServerProfile, limits: FleetLimits?, now: Date) -> HeadroomSnapshot {
        HeadroomSnapshot(
            serverID: profile.id,
            serverName: profile.name,
            isDemo: profile.isDemo,
            generatedAt: now,
            source: limits == nil ? .unavailable : .fleetLimits,
            providers: limits.map(HeadroomCalculator.fromFleet) ?? [],
            poolAccounts: limits?.credentials.map(PoolAccount.init(fleet:)) ?? []
        )
    }

    public var lowestHeadroom: ProviderHeadroom? {
        providers.filter { $0.headroomPercent != nil }.min { ($0.headroomPercent ?? 0) < ($1.headroomPercent ?? 0) }
    }

    public func pools(at now: Date) -> [ProviderPool] {
        PooledCapacity.pools(poolAccounts, now: now)
    }

    public func age(at now: Date) -> TimeInterval {
        now.timeIntervalSince(generatedAt)
    }
}

public enum HeadroomLoader {
    public static func load(profile: ServerProfile, secret: String, transport: any HTTPTransport, now: Date = Date()) async throws -> HeadroomSnapshot {
        switch profile.authMode {
        case .management:
            let client = ManagementClient(baseURL: profile.baseURL, managementKey: secret, transport: transport)
            return .management(profile, credentials: try await client.credentials().value.files, now: now)
        case .clientKey:
            let client = ClientKeyClient(baseURL: profile.baseURL, clientKey: secret, transport: transport)
            return .clientKey(profile, limits: try await client.fleetLimits(), now: now)
        }
    }
}
