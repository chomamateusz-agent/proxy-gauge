import Foundation
import Testing
import ProxyGaugeCore
@testable import ProxyGaugeStore

@Suite("Profile store")
struct ProfileStoreTests {
    func isolatedDefaults() -> UserDefaults {
        let suite = "proxygauge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func authFailureLatchIsSharedPerServerUntilReset() {
        let defaults = isolatedDefaults()
        let failing = UUID()
        let healthy = UUID()
        let writer = ProfileStore(defaults: defaults)
        var latch = writer.authFailureLatch(for: failing)
        latch.record(.unauthorized("invalid management key"))
        #expect(writer.saveAuthFailureLatch(latch, for: failing, generation: writer.authGeneration(for: failing)))

        let reader = ProfileStore(defaults: defaults)
        #expect(reader.authFailureLatch(for: failing).isBlocked)
        #expect(!reader.authFailureLatch(for: healthy).isBlocked)

        reader.resetAuthFailureLatch(for: failing)
        #expect(!ProfileStore(defaults: defaults).authFailureLatch(for: failing).isBlocked)
    }

    @Test func eachServerHasItsOwnLatchKey() {
        let defaults = isolatedDefaults()
        let first = UUID()
        let second = UUID()
        let store = ProfileStore(defaults: defaults)
        store.saveAuthFailureLatch(AuthFailureLatch(isBlocked: true), for: first, generation: 0)
        store.saveAuthFailureLatch(AuthFailureLatch(isBlocked: true), for: second, generation: 0)
        store.saveAuthFailureLatch(AuthFailureLatch(), for: second, generation: 0)
        #expect(store.authFailureLatch(for: first).isBlocked)
        #expect(!store.authFailureLatch(for: second).isBlocked)
        let latchKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(ProfileStore.authBlockedKeyPrefix) }
        #expect(Set(latchKeys) == [ProfileStore.authBlockedKeyPrefix + first.uuidString, ProfileStore.authBlockedKeyPrefix + second.uuidString])
    }

    @Test func staleWriterCannotBlockAServerAfterItsKeyIsSaved() {
        let defaults = isolatedDefaults()
        let server = UUID()
        let store = ProfileStore(defaults: defaults)
        let staleGeneration = store.authGeneration(for: server)
        store.resetAuthFailureLatch(for: server)
        let written = store.saveAuthFailureLatch(AuthFailureLatch(isBlocked: true), for: server, generation: staleGeneration)
        #expect(!written)
        #expect(!store.authFailureLatch(for: server).isBlocked)
        #expect(store.saveAuthFailureLatch(AuthFailureLatch(isBlocked: true), for: server, generation: store.authGeneration(for: server)))
        #expect(store.authFailureLatch(for: server).isBlocked)
    }

    @Test func emptyStoreStillOffersTheDemo() {
        let settings = ProfileStore(defaults: isolatedDefaults()).load()
        #expect(settings.profiles.isEmpty)
        #expect(settings.allProfiles == [.demo()])
        #expect(settings.defaultProfile.isDemo)
        #expect(settings.refreshInterval == 60)
    }

    @Test func profilesRoundTripWithoutTheDemoOrAnySecret() throws {
        let defaults = isolatedDefaults()
        let store = ProfileStore(defaults: defaults)
        let server = ServerProfile(name: "Home", baseURL: URL(string: "http://192.168.1.2:8317")!, authMode: .management)
        store.save(StoredSettings(profiles: [server, .demo()], defaultServerID: server.id, refreshInterval: 120, demoAuthMode: .clientKey))

        let loaded = store.load()
        #expect(loaded.profiles == [server])
        #expect(loaded.defaultProfile == server)
        #expect(loaded.refreshInterval == 120)
        #expect(loaded.demoProfile.authMode == .clientKey)
        let raw = try #require(defaults.data(forKey: ProfileStore.settingsKey))
        let text = String(decoding: raw, as: UTF8.self)
        #expect(!text.lowercased().contains("key\":\""))
    }

    @Test func corruptSettingsFallBackToDefaults() {
        let defaults = isolatedDefaults()
        defaults.set(Data("not json".utf8), forKey: ProfileStore.settingsKey)
        #expect(ProfileStore(defaults: defaults).load() == StoredSettings())
    }

    @Test func refreshIntervalHasAFloor() {
        #expect(StoredSettings(refreshInterval: 1).clampedRefreshInterval == 15)
    }

    @Test func snapshotRoundTrips() {
        let store = ProfileStore(defaults: isolatedDefaults())
        let snapshot = HeadroomSnapshot(
            serverID: UUID(),
            serverName: "Home",
            isDemo: false,
            generatedAt: Date(timeIntervalSince1970: 1_794_611_400),
            source: .passiveObservations,
            providers: [ProviderHeadroom(provider: "claude", headroomPercent: 40, limitingBarID: "weekly_all", resetsAt: nil, usableCredentials: 2, totalCredentials: 3, bars: [QuotaBar(id: "weekly_all", usedPercent: 60)])]
        )
        store.saveSnapshot(snapshot)
        #expect(store.loadSnapshot() == snapshot)
    }
}

@Suite("Server connection")
struct ServerConnectionTests {
    @Test func demoNeedsNoSecret() throws {
        let connection = try ServerConnection(profile: .demo(), secretStore: InMemorySecretStore())
        #expect(connection.secret == DemoTransport.secret)
    }

    @Test func missingSecretIsReported() {
        let profile = ServerProfile(name: "x", baseURL: URL(string: "http://nas:8317")!, authMode: .clientKey)
        #expect(throws: APIError.missingCredential) { try ServerConnection(profile: profile, secretStore: InMemorySecretStore()) }
    }

    @Test func storedSecretIsUsed() throws {
        let secrets = InMemorySecretStore()
        let profile = ServerProfile(name: "x", baseURL: URL(string: "http://nas:8317")!, authMode: .clientKey)
        try secrets.setSecret("test-value", for: profile.id)
        #expect(try ServerConnection(profile: profile, secretStore: secrets).secret == "test-value")
        try secrets.deleteSecret(for: profile.id)
        #expect(try secrets.secret(for: profile.id) == nil)
    }
}
