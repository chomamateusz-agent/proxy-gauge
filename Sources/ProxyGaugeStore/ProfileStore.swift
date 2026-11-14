import Foundation
import ProxyGaugeCore

public enum SharedConfiguration {
    public static let appGroupInfoKey = "ProxyGaugeAppGroup"
    public static let keychainGroupInfoKey = "ProxyGaugeKeychainGroup"

    public static var appGroup: String? { infoValue(appGroupInfoKey) }
    public static var keychainAccessGroup: String? { infoValue(keychainGroupInfoKey) }

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

public final class ProfileStore: @unchecked Sendable {
    static let settingsKey = "proxygauge.settings.v1"
    static let snapshotKey = "proxygauge.snapshot.v1"
    static let authBlockedKeyPrefix = "proxygauge.auth-blocked.v2."
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

    public func loadSnapshot() -> HeadroomSnapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKey) else { return nil }
        return try? JSONDecoder.wire().decode(HeadroomSnapshot.self, from: data)
    }

    public func saveSnapshot(_ snapshot: HeadroomSnapshot) {
        guard let data = try? JSONEncoder.wire().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.snapshotKey)
    }

    public func authFailureLatch(for serverID: UUID) -> AuthFailureLatch {
        AuthFailureLatch(isBlocked: defaults.bool(forKey: Self.authBlockedKeyPrefix + serverID.uuidString))
    }

    public func authGeneration(for serverID: UUID) -> Int {
        defaults.integer(forKey: Self.authGenerationKeyPrefix + serverID.uuidString)
    }

    @discardableResult
    public func saveAuthFailureLatch(_ latch: AuthFailureLatch, for serverID: UUID, generation: Int) -> Bool {
        guard authGeneration(for: serverID) == generation else { return false }
        defaults.set(latch.isBlocked, forKey: Self.authBlockedKeyPrefix + serverID.uuidString)
        return true
    }

    public func resetAuthFailureLatch(for serverID: UUID) {
        defaults.set(authGeneration(for: serverID) + 1, forKey: Self.authGenerationKeyPrefix + serverID.uuidString)
        defaults.removeObject(forKey: Self.authBlockedKeyPrefix + serverID.uuidString)
    }
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
