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

    public init(profiles: [ServerProfile] = [], defaultServerID: UUID? = nil, refreshInterval: TimeInterval = defaultRefreshInterval, demoAuthMode: AuthMode = .management) {
        self.profiles = profiles
        self.defaultServerID = defaultServerID
        self.refreshInterval = refreshInterval
        self.demoAuthMode = demoAuthMode
    }

    public var demoProfile: ServerProfile { .demo(authMode: demoAuthMode) }

    public var allProfiles: [ServerProfile] { profiles + [demoProfile] }

    public var defaultProfile: ServerProfile {
        allProfiles.first { $0.id == defaultServerID } ?? profiles.first ?? demoProfile
    }

    public var clampedRefreshInterval: TimeInterval { max(15, refreshInterval) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = (try? container.decode([ServerProfile].self, forKey: .profiles)) ?? []
        defaultServerID = try? container.decodeIfPresent(UUID.self, forKey: .defaultServerID)
        refreshInterval = (try? container.decode(TimeInterval.self, forKey: .refreshInterval)) ?? Self.defaultRefreshInterval
        demoAuthMode = (try? container.decode(AuthMode.self, forKey: .demoAuthMode)) ?? .management
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

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = SharedConfiguration.sharedDefaults()) {
        self.defaults = defaults
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

    public func forgetSnapshot(for serverID: UUID) {
        defaults.removeObject(forKey: Self.snapshotKeyPrefix + serverID.uuidString)
        defaults.removeObject(forKey: Self.previousSnapshotKeyPrefix + serverID.uuidString)
        defaults.removeObject(forKey: Self.widgetFetchAttemptKeyPrefix + serverID.uuidString)
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

    public func resetAuthFailureLatch(for serverID: UUID, pausedBy reason: AuthPauseReason? = nil) {
        let next = authGeneration(for: serverID) + 1
        saveAuthFailureLatch(AuthFailureLatch(pauseReason: reason), for: serverID, generation: next)
        defaults.set(next, forKey: Self.authGenerationKeyPrefix + serverID.uuidString)
        let current = Self.authPauseKey(serverID, generation: next)
        let serverPrefix = Self.authPauseKeyPrefix + serverID.uuidString + "."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(serverPrefix) && key != current {
            defaults.removeObject(forKey: key)
        }
    }

    static func authPauseKey(_ serverID: UUID, generation: Int) -> String {
        "\(authPauseKeyPrefix)\(serverID.uuidString).\(generation)"
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
