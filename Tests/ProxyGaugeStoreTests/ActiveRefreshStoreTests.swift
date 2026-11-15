import Foundation
import Synchronization
import Testing
import ProxyGaugeCore
@testable import ProxyGaugeStore

@Suite("Provider refresh state in the store")
struct ActiveRefreshStoreTests {
    let proxy = ActiveRefreshServer.proxyKey(URL(string: "https://proxy.example.com:8317")!)

    func isolatedStore() -> (ProfileStore, UserDefaults) {
        let suite = "proxygauge.active-store-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (ProfileStore(defaults: defaults), defaults)
    }

    @Test func anUnreadableEntryCountsAsJustAttemptedAndTheOthersSurvive() throws {
        let (store, defaults) = isolatedStore()
        let key = ProfileStore.activeRefreshKeyPrefix + proxy
        let goodUntil = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 86_400).rounded())
        let raw = #"{"good.json":{"nextAllowedAt":"\#(WireDate.format(goodUntil))","lastAttemptAt":"2026-11-15T10:00:00Z"},"bad.json":{"nextAllowedAt":"not a date"},"old.json":{"lastAttemptAt":"2026-11-15T10:00:00Z"}}"#
        defaults.set(Data(raw.utf8), forKey: key)
        let before = Date()

        let states = store.activeRefreshStates(proxy: proxy)

        #expect(states["good.json"]?.nextAllowedAt == goodUntil)
        #expect(states["old.json"]?.jitter == 0)
        #expect(states["old.json"]?.automaticSuspended == false)
        let bad = try #require(states["bad.json"])
        #expect((bad.lastAttemptAt ?? .distantPast) >= before.addingTimeInterval(-1))
        #expect((bad.nextAllowedAt ?? .distantPast) >= before.addingTimeInterval(ActiveRefreshPolicy.manualMinimum - 1))
        #expect(store.activeRefreshStates(proxy: proxy)["bad.json"] == states["bad.json"])
    }

    @Test func storedWaitsAreCappedAtSevenDays() throws {
        let (store, _) = isolatedStore()
        var state = ActiveRefreshState()
        state.nextAllowedAt = date("2999-01-01T00:00:00Z")
        state.rateLimitedUntil = date("2999-01-01T00:00:00Z")
        store.saveActiveRefreshState(state, credentialID: "a.json", proxy: proxy)
        let latest = Date().addingTimeInterval(ActiveRefreshPolicy.longestWait + 2)

        let read = try #require(store.activeRefreshStates(proxy: proxy)["a.json"])

        #expect(try #require(read.nextAllowedAt) <= latest)
        #expect(try #require(read.rateLimitedUntil) <= latest)
        #expect(try #require(read.rateLimitedUntil) > Date().addingTimeInterval(ActiveRefreshPolicy.longestWait - 60))
    }

    @Test func aCappedStoredWaitKeepsItsDeadlineAsTimePasses() throws {
        let suite = "proxygauge.active-store-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let start = Date(timeIntervalSince1970: 1_794_700_000)
        let now = Mutex(start)
        let store = ProfileStore(defaults: defaults, clock: { now.withLock { $0 } })
        let raw = #"{"a.json":{"nextAllowedAt":"2999-01-01T00:00:00Z","rateLimitedUntil":"2999-01-01T00:00:00Z"}}"#
        defaults.set(Data(raw.utf8), forKey: ProfileStore.activeRefreshKeyPrefix + proxy)

        let first = try #require(store.activeRefreshStates(proxy: proxy)["a.json"])
        now.withLock { $0 = start.addingTimeInterval(3_600) }
        let later = try #require(store.activeRefreshStates(proxy: proxy)["a.json"])

        let deadline = start.addingTimeInterval(ActiveRefreshPolicy.longestWait)
        #expect(first.nextAllowedAt == deadline)
        #expect(first.rateLimitedUntil == deadline)
        #expect(later.nextAllowedAt == deadline)
        #expect(later.rateLimitedUntil == deadline)
    }

    @Test func aCappedProxyBackoffKeepsItsEndAsTimePassesAndAcrossStores() throws {
        let suite = "proxygauge.active-store-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let start = Date(timeIntervalSince1970: 1_794_700_000)
        let now = Mutex(start)
        let store = ProfileStore(defaults: defaults, clock: { now.withLock { $0 } })
        store.saveProxyRefusalBackoff(ProxyRefusalBackoff(consecutiveRefusals: 1, until: start.addingTimeInterval(30 * 3_600)), proxy: proxy)
        let end = start.addingTimeInterval(ActiveRefreshPolicy.backoffCap)

        #expect(store.proxyRefusalBackoff(proxy: proxy)?.until == end)
        now.withLock { $0 = start.addingTimeInterval(3_600) }
        #expect(store.proxyRefusalBackoff(proxy: proxy)?.until == end)
        let reopened = ProfileStore(defaults: defaults, clock: { now.withLock { $0 } })
        #expect(reopened.proxyRefusalBackoff(proxy: proxy)?.until == end)

        now.withLock { $0 = end.addingTimeInterval(1) }
        #expect(reopened.proxyRefusalBackoff(proxy: proxy)?.until == end)
        #expect(reopened.proxyRefusalBackoff(proxy: proxy)?.automaticChecksResume(after: now.withLock { $0 }) == nil)
    }

    @Test func oneUnreadableReadingKeepsTheOthers() {
        let (store, defaults) = isolatedStore()
        let raw = #"{"good.json":{"credentialID":"good.json","provider":"claude","observedAt":"2026-11-15T10:00:00Z","windows":[]},"bad.json":{"credentialID":"bad.json","observedAt":"never"}}"#
        defaults.set(Data(raw.utf8), forKey: ProfileStore.activeQuotaKeyPrefix + proxy)

        let readings = store.activeQuotas(proxy: proxy)

        #expect(readings.keys.sorted() == ["good.json"])
    }

    @Test func anEditThatKeepsAddressAndKeyKeepsTheSnapshotUnderTheNewName() throws {
        let (store, _) = isolatedStore()
        let profile = ServerProfile(name: "Home", baseURL: URL(string: "https://proxy.example.com:8317")!, authMode: .management)
        store.saveSnapshot(HeadroomSnapshot.management(profile, credentials: [], now: .now))

        store.resetAuthFailureLatch(for: profile.id, keepingSnapshotNamed: "Home renamed")
        #expect(store.snapshot(for: profile.id)?.serverName == "Home renamed")

        store.resetAuthFailureLatch(for: profile.id)
        #expect(store.snapshot(for: profile.id) == nil)
    }

    @Test func savedWaitsAreNeverShortened() throws {
        let (store, _) = isolatedStore()
        var state = ActiveRefreshState()
        let until = Date(timeIntervalSince1970: 1_794_700_000.4)
        state.nextAllowedAt = until
        state.rateLimitedUntil = until
        store.saveActiveRefreshState(state, credentialID: "a.json", proxy: proxy)

        let read = try #require(store.activeRefreshStates(proxy: proxy)["a.json"])
        #expect(try #require(read.nextAllowedAt) >= until)
        #expect(try #require(read.rateLimitedUntil) >= until)
    }

    @Test func forgettingAServerKeepsWhatItsProxySharesAndDropsLateWrites() {
        let (store, _) = isolatedStore()
        let serverID = UUID()
        let server = ActiveRefreshServer(serverID: serverID, baseURL: URL(string: "https://proxy.example.com:8317")!, generation: store.authGeneration(for: serverID))
        var state = ActiveRefreshState()
        state.nextAllowedAt = .now.addingTimeInterval(3_600)
        store.saveActiveRefreshState(state, credentialID: "a.json", proxy: proxy)
        #expect(store.saveActiveQuota(ActiveQuota(credentialID: "a.json", provider: "claude", observedAt: .now), for: server))

        store.forgetServer(serverID)

        #expect(store.activeQuotas(proxy: server.proxy).keys.sorted() == ["a.json"])
        #expect(store.activeRefreshStates(proxy: proxy)["a.json"]?.nextAllowedAt != nil)
        #expect(!store.saveActiveQuota(ActiveQuota(credentialID: "b.json", provider: "claude", observedAt: .now), for: server))
        #expect(store.activeQuotas(proxy: server.proxy)["b.json"] == nil)

        store.forgetActiveQuotas(proxy: server.proxy)
        #expect(store.activeQuotas(proxy: server.proxy).isEmpty)
    }
}

func date(_ text: String) -> Date {
    WireDate.parse(text)!
}
