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
        let generation = writer.authGeneration(for: failing)
        var latch = writer.authFailureLatch(for: failing, generation: generation)
        latch.record(.unauthorized("invalid management key"))
        writer.saveAuthFailureLatch(latch, for: failing, generation: generation)

        let reader = ProfileStore(defaults: defaults)
        #expect(reader.authFailureLatch(for: failing, generation: reader.authGeneration(for: failing)).pauseReason == .keyRejected)
        #expect(!reader.authFailureLatch(for: healthy, generation: reader.authGeneration(for: healthy)).isBlocked)

        reader.resetAuthFailureLatch(for: failing)
        let fresh = ProfileStore(defaults: defaults)
        #expect(!fresh.authFailureLatch(for: failing, generation: fresh.authGeneration(for: failing)).isBlocked)
    }

    @Test func eachServerAndGenerationHasItsOwnLatchKey() {
        let defaults = isolatedDefaults()
        let first = UUID()
        let second = UUID()
        let store = ProfileStore(defaults: defaults)
        store.saveAuthFailureLatch(AuthFailureLatch(pauseReason: .ipBanned), for: first, generation: 0)
        store.saveAuthFailureLatch(AuthFailureLatch(pauseReason: .keyRejected), for: second, generation: 0)
        store.saveAuthFailureLatch(AuthFailureLatch(), for: second, generation: 0)
        #expect(store.authFailureLatch(for: first, generation: 0).pauseReason == .ipBanned)
        #expect(!store.authFailureLatch(for: second, generation: 0).isBlocked)
        let latchKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(ProfileStore.authPauseKeyPrefix) }
        #expect(Set(latchKeys) == [ProfileStore.authPauseKey(first, generation: 0)])
    }

    @Test func lateWriteForARetiredGenerationIsInert() {
        let defaults = isolatedDefaults()
        let server = UUID()
        let widget = ProfileStore(defaults: defaults)
        let app = ProfileStore(defaults: defaults)
        let widgetGeneration = widget.authGeneration(for: server)
        #expect(!widget.authFailureLatch(for: server, generation: widgetGeneration).isBlocked)

        app.resetAuthFailureLatch(for: server)
        widget.saveAuthFailureLatch(AuthFailureLatch(pauseReason: .keyRejected), for: server, generation: widgetGeneration)

        let current = app.authGeneration(for: server)
        #expect(current == widgetGeneration + 1)
        #expect(!app.authFailureLatch(for: server, generation: current).isBlocked)
        app.saveAuthFailureLatch(AuthFailureLatch(pauseReason: .keyRejected), for: server, generation: current)
        #expect(app.authFailureLatch(for: server, generation: current).isBlocked)
    }

    @Test func resetCanStartTheNewGenerationAlreadyPaused() {
        let defaults = isolatedDefaults()
        let server = UUID()
        let store = ProfileStore(defaults: defaults)
        store.saveAuthFailureLatch(AuthFailureLatch(pauseReason: .ipBanned), for: server, generation: 0)
        store.resetAuthFailureLatch(for: server, pausedBy: .keyRejected)
        #expect(store.authGeneration(for: server) == 1)
        #expect(store.authFailureLatch(for: server, generation: 1).pauseReason == .keyRejected)
        let latchKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(ProfileStore.authPauseKeyPrefix) }
        #expect(Set(latchKeys) == [ProfileStore.authPauseKey(server, generation: 1)])
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
