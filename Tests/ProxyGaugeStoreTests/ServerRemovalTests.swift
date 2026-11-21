import Foundation
import Testing
import ProxyGaugeCore
@testable import ProxyGaugeStore

@Suite("Removing servers and the demo")
struct ServerRemovalTests {
    let home = ServerProfile(name: "Home", baseURL: URL(string: "http://192.168.1.2:8317")!, authMode: .management)

    func isolatedDefaults() -> UserDefaults {
        let suite = "proxygauge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func snapshot(for serverID: UUID) -> HeadroomSnapshot {
        HeadroomSnapshot(
            serverID: serverID,
            serverName: "Demo server",
            isDemo: serverID == ServerProfile.demoID,
            generatedAt: Date(timeIntervalSince1970: 1_794_611_400),
            source: .passiveObservations,
            providers: [],
            poolAccounts: [PoolAccount(provider: "claude", availability: .available, bars: [QuotaBar(id: "weekly_all", usedPercent: 60)])]
        )
    }

    @Test func deletingTheDemoHidesItAndPersists() {
        let store = ProfileStore(defaults: isolatedDefaults())
        var settings = StoredSettings(profiles: [home], defaultServerID: ServerProfile.demoID, demoAuthMode: .clientKey)
        settings.removeServer(ServerProfile.demoID)
        store.save(settings)

        let loaded = store.load()
        #expect(loaded.allProfiles == [home])
        #expect(loaded.defaultProfile == home)
        #expect(loaded.defaultServerID == home.id)
        #expect(!loaded.showsDemo)
    }

    @Test func deletingTheOnlyServerLeavesNoDefault() {
        var settings = StoredSettings()
        settings.removeServer(ServerProfile.demoID)
        #expect(settings.allProfiles.isEmpty)
        #expect(settings.defaultProfile == nil)
        #expect(settings.profile(for: ServerProfile.demoID) == nil)
    }

    @Test func launchWithoutAStoredDefaultOpensTheFirstServer() {
        let work = ServerProfile(name: "Work", baseURL: URL(string: "http://10.0.0.2:8317")!, authMode: .clientKey)
        #expect(StoredSettings(profiles: [home, work]).defaultProfile == home)
        #expect(StoredSettings(profiles: [home, work], defaultServerID: UUID()).defaultProfile == home)
        #expect(StoredSettings(profiles: [home, work], defaultServerID: work.id).defaultProfile == work)
    }

    @Test func deletingTheDefaultServerFallsBackToTheNextOne() {
        let work = ServerProfile(name: "Work", baseURL: URL(string: "http://10.0.0.2:8317")!, authMode: .clientKey)
        var settings = StoredSettings(profiles: [home, work], defaultServerID: home.id, showsDemo: false)
        settings.removeServer(home.id)
        #expect(settings.defaultProfile == work)
        settings.removeServer(work.id)
        #expect(settings.defaultProfile == nil)
    }

    @Test func restoredDemoStartsInManagementMode() {
        var settings = StoredSettings(demoAuthMode: .clientKey)
        settings.removeServer(ServerProfile.demoID)
        settings.restoreDemo()
        #expect(settings.allProfiles == [.demo(authMode: .management)])
    }

    @Test func widgetsPointingAtADeletedServerFallBackToTheDefault() {
        var settings = StoredSettings(profiles: [home], defaultServerID: home.id)
        #expect(settings.profile(for: ServerProfile.demoID)?.isDemo == true)
        settings.removeServer(ServerProfile.demoID)
        #expect(settings.profile(for: ServerProfile.demoID) == home)
        #expect(settings.profile(for: nil) == home)
    }

    @Test func removalForgetsTheManualRefreshChoice() {
        var settings = StoredSettings(profiles: [home])
        settings.setRefreshesAutomatically(false, for: home.id)
        settings.setRefreshesAutomatically(false, for: ServerProfile.demoID)
        settings.removeServer(ServerProfile.demoID)
        #expect(settings.manualRefreshServerIDs == [home.id])
    }

    @Test func forgettingTheDemoClearsItsSnapshotPauseAndWidgetAttempt() {
        let defaults = isolatedDefaults()
        let store = ProfileStore(defaults: defaults)
        let demo = ServerProfile.demoID
        store.saveSnapshot(snapshot(for: demo))
        store.saveSnapshot(snapshot(for: home.id))
        store.recordWidgetFetchAttempt(Date(timeIntervalSince1970: 1_794_611_400), for: demo)
        store.saveAuthFailureLatch(AuthFailureLatch(pauseReason: .keyRejected), for: demo, generation: store.authGeneration(for: demo))
        let generationBefore = store.authGeneration(for: demo)

        store.forgetServer(demo)

        #expect(store.snapshot(for: demo) == nil)
        #expect(store.lastWidgetFetchAttempt(for: demo) == nil)
        #expect(store.authGeneration(for: demo) == generationBefore + 1)
        #expect(!store.authFailureLatch(for: demo, generation: store.authGeneration(for: demo)).isBlocked)
        let leftovers = defaults.dictionaryRepresentation().keys.filter { $0.contains(demo.uuidString) && !$0.hasPrefix(ProfileStore.authGenerationKeyPrefix) }
        #expect(leftovers.isEmpty)
        #expect(store.snapshot(for: home.id) != nil)
    }

    @Test func lateWidgetSnapshotForAForgottenServerIsDropped() {
        let store = ProfileStore(defaults: isolatedDefaults())
        let demo = ServerProfile.demoID
        let widgetGeneration = store.authGeneration(for: demo)
        store.forgetServer(demo)
        store.saveSnapshot(snapshot(for: demo), authGeneration: widgetGeneration)
        #expect(store.snapshot(for: demo) == nil)
    }

    @Test func manualRefreshChoiceRoundTripsAndOldSettingsDefaultToAutomatic() throws {
        let defaults = isolatedDefaults()
        let store = ProfileStore(defaults: defaults)
        var settings = StoredSettings(profiles: [home])
        settings.setRefreshesAutomatically(false, for: home.id)
        store.save(settings)
        #expect(!store.load().refreshesAutomatically(home.id))
        #expect(store.load().refreshesAutomatically(ServerProfile.demoID))

        let legacy = #"{"profiles":[],"refreshInterval":60,"demoAuthMode":"management"}"#
        defaults.set(Data(legacy.utf8), forKey: ProfileStore.settingsKey)
        let migrated = store.load()
        #expect(migrated.showsDemo)
        #expect(migrated.refreshesAutomatically(ServerProfile.demoID))
    }
}
