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

    public static func management(_ profile: ServerProfile, credentials: [Credential], active: [String: ActiveQuota] = [:], generatedAt: Date? = nil, now: Date) -> HeadroomSnapshot {
        HeadroomSnapshot(
            serverID: profile.id,
            serverName: profile.name,
            isDemo: profile.isDemo,
            generatedAt: generatedAt ?? now,
            source: .passiveObservations,
            providers: HeadroomCalculator.fromCredentials(credentials, active: active, now: now),
            poolAccounts: credentials.map { PoolAccount(credential: $0, active: active[$0.stableID], now: now) }
        )
    }

    public static func clientKey(_ profile: ServerProfile, limits: FleetLimits?, generatedAt: Date? = nil, now: Date) -> HeadroomSnapshot {
        HeadroomSnapshot(
            serverID: profile.id,
            serverName: profile.name,
            isDemo: profile.isDemo,
            generatedAt: generatedAt ?? now,
            source: limits == nil ? .unavailable : .fleetLimits,
            providers: limits.map { HeadroomCalculator.fromFleet($0, now: now) } ?? [],
            poolAccounts: limits?.credentials.map(PoolAccount.init(fleet:)) ?? []
        )
    }

    public func renamed(_ name: String) -> HeadroomSnapshot {
        var renamed = self
        renamed.serverName = name
        return renamed
    }

    public func applying(active: [String: ActiveQuota]) -> HeadroomSnapshot {
        var updated = self
        updated.poolAccounts = poolAccounts.map { account in
            account.applying(account.credentialID.flatMap { active[$0] })
        }
        return updated
    }

    public func lowestHeadroom(at now: Date) -> ProviderHeadroom? {
        headroom(at: now).filter { $0.headroomPercent != nil }.min { ($0.headroomPercent ?? 0) < ($1.headroomPercent ?? 0) }
    }

    public func pools(at now: Date) -> [ProviderPool] {
        PooledCapacity.pools(poolAccounts, now: now)
    }

    public func headroom(at now: Date) -> [ProviderHeadroom] {
        let recomputed = HeadroomCalculator.fromPoolAccounts(poolAccounts, now: now)
        let covered = Set(recomputed.map(\.provider))
        return (recomputed + providers.filter { !covered.contains($0.provider) }).sortedForDisplay()
    }

    public func age(at now: Date) -> TimeInterval {
        now.timeIntervalSince(generatedAt)
    }
}

public struct QuotaOverview: Sendable, Equatable {
    public var pools: [ProviderPool]
    public var headroom: [ProviderHeadroom]
    public var savedAt: Date?

    public static let empty = QuotaOverview(pools: [], headroom: [], savedAt: nil)

    public init(pools: [ProviderPool], headroom: [ProviderHeadroom], savedAt: Date?) {
        self.pools = pools
        self.headroom = headroom
        self.savedAt = savedAt
    }

    public init(snapshot: HeadroomSnapshot, isSaved: Bool, now: Date) {
        self.init(pools: snapshot.pools(at: now), headroom: snapshot.headroom(at: now), savedAt: isSaved ? snapshot.generatedAt : nil)
    }

    public var lowestHeadroom: Double? {
        headroom.compactMap(\.headroomPercent).min()
    }
}

public enum HeadroomLoader {
    public static func load(profile: ServerProfile, secret: String, transport: any HTTPTransport, active: [String: ActiveQuota] = [:], now: Date = Date()) async throws -> HeadroomSnapshot {
        switch profile.authMode {
        case .management:
            let client = ManagementClient(baseURL: profile.baseURL, managementKey: secret, transport: transport)
            return .management(profile, credentials: try await client.credentials().value.files, active: active, now: now)
        case .clientKey:
            let client = ClientKeyClient(baseURL: profile.baseURL, clientKey: secret, transport: transport)
            return .clientKey(profile, limits: try await client.fleetLimits(), now: now)
        }
    }
}
