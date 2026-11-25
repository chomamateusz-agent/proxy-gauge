import Foundation
import ProxyGaugeCore

public enum SharedConfiguration {
    public static let appGroupInfoKey = "ProxyGaugeAppGroup"
    public static let keychainGroupInfoKey = "ProxyGaugeKeychainGroup"
    public static let urlSchemeInfoKey = "ProxyGaugeURLScheme"

    public static var appGroup: String? { infoValue(appGroupInfoKey) }
    public static var keychainAccessGroup: String? { infoValue(keychainGroupInfoKey) }
    public static var urlScheme: String? { infoValue(urlSchemeInfoKey) }

    public static func sharedDefaults() -> UserDefaults {
        appGroup.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$(")
        else { return nil }
        return value
    }
}

public struct StoredSettings: Codable, Equatable, Sendable {
    public static let defaultRefreshInterval: TimeInterval = 60
    public static let refreshIntervalChoices: [TimeInterval] = [30, 60, 120, 300, 900]

    public var profiles: [ServerProfile]
    public var defaultServerID: UUID?
    public var refreshInterval: TimeInterval
    public var demoAuthMode: AuthMode
    public var showsDemo: Bool
    public var manualRefreshServerIDs: Set<UUID>
    public var providerRefreshServerIDs: Set<UUID>
    public var providerRefreshIntervals: [UUID: TimeInterval]

    public init(
        profiles: [ServerProfile] = [],
        defaultServerID: UUID? = nil,
        refreshInterval: TimeInterval = defaultRefreshInterval,
        demoAuthMode: AuthMode = .management,
        showsDemo: Bool = true,
        manualRefreshServerIDs: Set<UUID> = [],
        providerRefreshServerIDs: Set<UUID> = [],
        providerRefreshIntervals: [UUID: TimeInterval] = [:]
    ) {
        self.profiles = profiles
        self.defaultServerID = defaultServerID
        self.refreshInterval = refreshInterval
        self.demoAuthMode = demoAuthMode
        self.showsDemo = showsDemo
        self.manualRefreshServerIDs = manualRefreshServerIDs
        self.providerRefreshServerIDs = providerRefreshServerIDs
        self.providerRefreshIntervals = providerRefreshIntervals
    }

    public var demoProfile: ServerProfile { .demo(authMode: demoAuthMode) }

    public var allProfiles: [ServerProfile] { profiles + (showsDemo ? [demoProfile] : []) }

    public var defaultProfile: ServerProfile? {
        allProfiles.first { $0.id == defaultServerID } ?? allProfiles.first
    }

    public func profile(for serverID: UUID?) -> ServerProfile? {
        allProfiles.first { $0.id == serverID } ?? defaultProfile
    }

    public var clampedRefreshInterval: TimeInterval { max(15, refreshInterval) }

    public func refreshesAutomatically(_ serverID: UUID) -> Bool {
        !manualRefreshServerIDs.contains(serverID)
    }

    public mutating func setRefreshesAutomatically(_ enabled: Bool, for serverID: UUID) {
        if enabled {
            manualRefreshServerIDs.remove(serverID)
        } else {
            manualRefreshServerIDs.insert(serverID)
        }
    }

    public func refreshesLimitsFromProviders(_ serverID: UUID) -> Bool {
        providerRefreshServerIDs.contains(serverID)
    }

    public mutating func setRefreshesLimitsFromProviders(_ enabled: Bool, for serverID: UUID) {
        if enabled {
            providerRefreshServerIDs.insert(serverID)
        } else {
            providerRefreshServerIDs.remove(serverID)
        }
    }

    public func providerRefreshInterval(_ serverID: UUID) -> TimeInterval {
        let stored = providerRefreshIntervals[serverID] ?? ActiveRefreshPolicy.defaultAutomaticInterval
        return ActiveRefreshPolicy.automaticIntervalChoices.contains(stored) ? stored : ActiveRefreshPolicy.defaultAutomaticInterval
    }

    public mutating func setProviderRefreshInterval(_ interval: TimeInterval, for serverID: UUID) {
        providerRefreshIntervals[serverID] = interval
    }

    public mutating func removeServer(_ serverID: UUID) {
        if serverID == ServerProfile.demoID {
            showsDemo = false
            demoAuthMode = .management
        }
        profiles.removeAll { $0.id == serverID }
        manualRefreshServerIDs.remove(serverID)
        providerRefreshServerIDs.remove(serverID)
        providerRefreshIntervals[serverID] = nil
        if defaultServerID == serverID {
            defaultServerID = profiles.first?.id
        }
    }

    public mutating func restoreDemo() {
        showsDemo = true
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = (try? container.decode([ServerProfile].self, forKey: .profiles)) ?? []
        defaultServerID = try? container.decodeIfPresent(UUID.self, forKey: .defaultServerID)
        refreshInterval = (try? container.decode(TimeInterval.self, forKey: .refreshInterval)) ?? Self.defaultRefreshInterval
        demoAuthMode = (try? container.decode(AuthMode.self, forKey: .demoAuthMode)) ?? .management
        showsDemo = (try? container.decode(Bool.self, forKey: .showsDemo)) ?? true
        manualRefreshServerIDs = (try? container.decode(Set<UUID>.self, forKey: .manualRefreshServerIDs)) ?? []
        providerRefreshServerIDs = (try? container.decode(Set<UUID>.self, forKey: .providerRefreshServerIDs)) ?? []
        providerRefreshIntervals = (try? container.decode([UUID: TimeInterval].self, forKey: .providerRefreshIntervals)) ?? [:]
    }
}

public final class ProfileStore: SnapshotCache, @unchecked Sendable {
    static let settingsKey = "proxygauge.settings.v1"
    static let legacySnapshotKey = "proxygauge.snapshot.v1"
    static let previousSnapshotKeyPrefix = "proxygauge.snapshot.v2."
    static let snapshotKeyPrefix = "proxygauge.snapshot.v3."
    static let widgetFetchAttemptKeyPrefix = "proxygauge.widget-fetch-attempt.v1."
    static let authPauseKeyPrefix = "proxygauge.auth-pause.v3."
    static let authGenerationKeyPrefix = "proxygauge.auth-generation.v1."
    static let activeRefreshKeyPrefix = "proxygauge.active-refresh.v2."
    static let previousActiveQuotaKeyPrefix = "proxygauge.active-quota.v2."
    static let activeQuotaKeyPrefix = "proxygauge.active-quota.v3."
    static let proxyRefusalKeyPrefix = "proxygauge.proxy-refusal.v1."

    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private let lock = NSRecursiveLock()

    public init(defaults: UserDefaults = SharedConfiguration.sharedDefaults(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
    }

    public func load() -> StoredSettings {
        guard let data = defaults.data(forKey: Self.settingsKey),
              let settings = try? JSONDecoder.wire().decode(StoredSettings.self, from: data)
        else { return StoredSettings() }
        return settings
    }

    public func save(_ settings: StoredSettings) {
        var persisted = settings
        persisted.profiles.removeAll(where: \.isDemo)
        guard let data = try? JSONEncoder.wire().encode(persisted) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }

    public func snapshot(for serverID: UUID) -> HeadroomSnapshot? {
        guard let stored = storedSnapshot(for: serverID), stored.authGeneration == authGeneration(for: serverID) else { return nil }
        return stored.snapshot
    }

    public func saveSnapshot(_ snapshot: HeadroomSnapshot) {
        saveSnapshot(snapshot, authGeneration: authGeneration(for: snapshot.serverID))
    }

    public func saveSnapshot(_ snapshot: HeadroomSnapshot, authGeneration generation: Int) {
        let serverID = snapshot.serverID
        guard generation == authGeneration(for: serverID) else { return }
        if let current = storedSnapshot(for: serverID), current.authGeneration == generation, current.snapshot.generatedAt > snapshot.generatedAt {
            return
        }
        guard let data = try? JSONEncoder.wire().encode(StoredSnapshot(authGeneration: generation, snapshot: snapshot)) else { return }
        defaults.set(data, forKey: Self.snapshotKeyPrefix + serverID.uuidString)
        defaults.removeObject(forKey: Self.previousSnapshotKeyPrefix + serverID.uuidString)
        defaults.removeObject(forKey: Self.legacySnapshotKey)
    }

    private func storedSnapshot(for serverID: UUID) -> StoredSnapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKeyPrefix + serverID.uuidString),
              let stored = try? JSONDecoder.wire().decode(StoredSnapshot.self, from: data),
              stored.snapshot.serverID == serverID
        else { return nil }
        return stored
    }

    public func forgetServer(_ serverID: UUID) {
        lock.withLock {
            resetAuthFailureLatch(for: serverID)
            forgetSnapshot(for: serverID)
        }
    }

    public func forgetSnapshot(for serverID: UUID) {
        lock.withLock {
            defaults.removeObject(forKey: Self.previousActiveQuotaKeyPrefix + serverID.uuidString)
            defaults.removeObject(forKey: Self.snapshotKeyPrefix + serverID.uuidString)
            defaults.removeObject(forKey: Self.previousSnapshotKeyPrefix + serverID.uuidString)
            defaults.removeObject(forKey: Self.widgetFetchAttemptKeyPrefix + serverID.uuidString)
        }
    }

    public func lastWidgetFetchAttempt(for serverID: UUID) -> Date? {
        defaults.object(forKey: Self.widgetFetchAttemptKeyPrefix + serverID.uuidString) as? Date
    }

    public func recordWidgetFetchAttempt(_ date: Date, for serverID: UUID) {
        defaults.set(date, forKey: Self.widgetFetchAttemptKeyPrefix + serverID.uuidString)
    }

    public func cachedProviders() -> [String] {
        let snapshots = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.snapshotKeyPrefix) }
            .compactMap { UUID(uuidString: String($0.dropFirst(Self.snapshotKeyPrefix.count))).flatMap(snapshot(for:)) }
        return Array(Set(snapshots.flatMap { $0.poolAccounts.map(\.provider) + $0.providers.map(\.provider) }))
    }

    public func authGeneration(for serverID: UUID) -> Int {
        defaults.integer(forKey: Self.authGenerationKeyPrefix + serverID.uuidString)
    }

    public func authFailureLatch(for serverID: UUID, generation: Int) -> AuthFailureLatch {
        let stored = defaults.string(forKey: Self.authPauseKey(serverID, generation: generation))
        return AuthFailureLatch(pauseReason: stored.flatMap(AuthPauseReason.init(rawValue:)))
    }

    public func saveAuthFailureLatch(_ latch: AuthFailureLatch, for serverID: UUID, generation: Int) {
        let key = Self.authPauseKey(serverID, generation: generation)
        if let reason = latch.pauseReason {
            defaults.set(reason.rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public func resetAuthFailureLatch(for serverID: UUID, pausedBy reason: AuthPauseReason? = nil, keepingSnapshotNamed name: String? = nil) {
        lock.withLock {
            let kept = name.flatMap { name in snapshot(for: serverID).map { $0.renamed(name) } }
            let next = authGeneration(for: serverID) + 1
            saveAuthFailureLatch(AuthFailureLatch(pauseReason: reason), for: serverID, generation: next)
            defaults.set(next, forKey: Self.authGenerationKeyPrefix + serverID.uuidString)
            if let kept { saveSnapshot(kept, authGeneration: next) }
            let current = Self.authPauseKey(serverID, generation: next)
            let serverPrefix = Self.authPauseKeyPrefix + serverID.uuidString + "."
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(serverPrefix) && key != current {
                defaults.removeObject(forKey: key)
            }
        }
    }

    static func authPauseKey(_ serverID: UUID, generation: Int) -> String {
        "\(authPauseKeyPrefix)\(serverID.uuidString).\(generation)"
    }
}

extension ProfileStore: ActiveRefreshStore {
    public func activeRefreshStates(proxy: String) -> [String: ActiveRefreshState] {
        lock.withLock {
            let key = Self.activeRefreshKeyPrefix + proxy
            guard let data = defaults.data(forKey: key),
                  let entries = try? JSONDecoder.wire().decode([String: StoredRefreshState].self, from: data)
            else { return [:] }
            let readAt = Date(timeIntervalSince1970: clock().timeIntervalSince1970.rounded(.up))
            let states = entries.mapValues { ($0.state ?? .assumingAttempt(at: readAt)).cappingWaits(at: readAt) }
            if entries.contains(where: { credentialID, entry in entry.state != states[credentialID] }) {
                encode(states, forKey: key)
            }
            return states
        }
    }

    public func saveActiveRefreshState(_ state: ActiveRefreshState, credentialID: String, proxy: String) {
        restoreActiveRefreshState(state, credentialID: credentialID, proxy: proxy)
    }

    public func restoreActiveRefreshState(_ state: ActiveRefreshState?, credentialID: String, proxy: String) {
        lock.withLock {
            var states = activeRefreshStates(proxy: proxy)
            states[credentialID] = state
            encode(states, forKey: Self.activeRefreshKeyPrefix + proxy)
        }
    }

    public func activeQuotas(proxy: String) -> [String: ActiveQuota] {
        lock.withLock {
            guard let data = defaults.data(forKey: Self.activeQuotaKeyPrefix + proxy),
                  let entries = try? JSONDecoder.wire().decode([String: StoredActiveQuota].self, from: data)
            else { return [:] }
            return entries.compactMapValues(\.quota)
        }
    }

    @discardableResult
    public func saveActiveQuota(_ quota: ActiveQuota, for server: ActiveRefreshServer) -> Bool {
        lock.withLock {
            guard server.generation == authGeneration(for: server.serverID) else { return false }
            var quotas = activeQuotas(proxy: server.proxy)
            quotas[quota.credentialID] = quota
            encode(quotas, forKey: Self.activeQuotaKeyPrefix + server.proxy)
            return true
        }
    }

    public func proxyRefusalBackoff(proxy: String) -> ProxyRefusalBackoff? {
        lock.withLock {
            let key = Self.proxyRefusalKeyPrefix + proxy
            guard let stored = defaults.data(forKey: key).flatMap({ try? JSONDecoder.wire().decode(ProxyRefusalBackoff.self, from: $0) }) else { return nil }
            let capped = stored.capped(at: clock())
            if capped != stored { encode(capped, forKey: key) }
            return capped
        }
    }

    public func saveProxyRefusalBackoff(_ backoff: ProxyRefusalBackoff?, proxy: String) {
        lock.withLock {
            guard let backoff else {
                defaults.removeObject(forKey: Self.proxyRefusalKeyPrefix + proxy)
                return
            }
            encode(backoff, forKey: Self.proxyRefusalKeyPrefix + proxy)
        }
    }

    public func forgetActiveQuotas(proxy: String) {
        lock.withLock {
            defaults.removeObject(forKey: Self.activeQuotaKeyPrefix + proxy)
        }
    }

    public func discardPreviousActiveQuotas() {
        lock.withLock {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.previousActiveQuotaKeyPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func encode(_ value: some Encodable, forKey key: String) {
        guard let data = try? JSONEncoder.wire().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

struct StoredRefreshState: Decodable {
    var state: ActiveRefreshState?

    init(from decoder: Decoder) throws {
        state = try? ActiveRefreshState(from: decoder)
    }
}

struct StoredActiveQuota: Decodable {
    var quota: ActiveQuota?

    init(from decoder: Decoder) throws {
        quota = try? ActiveQuota(from: decoder)
        if let quota, ["claude", "codex"].contains(quota.provider.lowercased()),
           let resets = quota.resets, resets.remaining > 0, !resets.hasUsabilityDetails {
            self.quota?.resets = nil
        }
    }
}

struct StoredSnapshot: Codable {
    var authGeneration: Int
    var snapshot: HeadroomSnapshot
}

public struct ServerConnection: Sendable {
    public var profile: ServerProfile
    public var secret: String
    public var transport: any HTTPTransport

    public init(profile: ServerProfile, secretStore: any SecretStore, liveTransport: any HTTPTransport = URLSessionTransport()) throws {
        self.profile = profile
        if profile.isDemo {
            secret = DemoTransport.secret
            transport = DemoTransport.shared
            return
        }
        let stored: String?
        do {
            stored = try secretStore.secret(for: profile.id)
        } catch {
            throw APIError.credentialUnavailable(String(describing: error))
        }
        guard let stored, !stored.isEmpty else {
            throw APIError.missingCredential
        }
        secret = stored
        transport = liveTransport
    }

    public var management: ManagementClient {
        ManagementClient(baseURL: profile.baseURL, managementKey: secret, transport: transport)
    }

    public var client: ClientKeyClient {
        ClientKeyClient(baseURL: profile.baseURL, clientKey: secret, transport: transport)
    }
}
