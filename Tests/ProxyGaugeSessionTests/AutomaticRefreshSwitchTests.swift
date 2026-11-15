import Foundation
import ProxyGaugeCore
import Testing
@testable import ProxyGaugeSession

@Suite("Automatic refresh switch")
@MainActor
struct AutomaticRefreshSwitchTests {
    static let modelsRoute = "GET /v8/management/credentials/models"
    static let credentialsRoute = "GET /v8/management/credentials"

    func harnessWithModels() -> SessionHarness {
        let harness = SessionHarness()
        harness.server.overrides[Self.modelsRoute] = HTTPResponse(statusCode: 200, body: Data(#"{"models":[{"id":"claude-opus-5-5"}]}"#.utf8))
        return harness
    }

    @Test func offSendsNoAutomaticRequestForAnyScope() async {
        let harness = harnessWithModels()
        let session = harness.makeSession()
        session.refreshesAutomatically = false

        for scope in [RefreshScope.accounts, .usage, .models, .settings, .accountModels("a.json")] {
            await session.refresh(scope, trigger: .automatic, dropIfCancelled: true)
        }

        #expect(harness.server.log.isEmpty)
        #expect(session.loadPhase(for: .accounts, loaded: session.accountsLoaded) == .waitingForManualRefresh)
    }

    @Test func offStillLetsAManualRefreshThrough() async {
        let harness = SessionHarness()
        let session = harness.makeSession()
        session.refreshesAutomatically = false

        await session.refresh(.accounts, trigger: .manual)

        #expect(session.accountsLoaded)
        #expect(harness.server.requests(Self.credentialsRoute) == 1)
        await session.refresh(.accounts, trigger: .automatic)
        #expect(harness.server.requests(Self.credentialsRoute) == 1)
    }

    @Test func failedLoadIsNotRetriedAutomaticallyWhenOff() async {
        let harness = SessionHarness()
        harness.server.overrides[Self.credentialsRoute] = HTTPResponse(statusCode: 500, body: Data())
        let session = harness.makeSession()
        session.refreshesAutomatically = false

        await session.refresh(.accounts, trigger: .manual)
        await session.refresh(.accounts, trigger: .automatic)

        #expect(harness.server.requests(Self.credentialsRoute) == 1)
    }

    @Test func switchingOffAnOpenSessionStopsItsAutomaticRefreshes() async {
        let harness = SessionHarness()
        let session = harness.makeSession()
        await session.refresh(.accounts, trigger: .automatic)
        session.refreshesAutomatically = false

        await session.refresh(.accounts, trigger: .automatic)

        #expect(harness.server.requests(Self.credentialsRoute) == 1)
    }

    @Test func accountDetailPullLoadsMissingModelsButDoesNotRefetchThemWhenOff() async {
        let harness = harnessWithModels()
        let session = harness.makeSession()
        session.refreshesAutomatically = false

        await session.refreshAccountDetail("a.json")
        #expect(session.accountModels["a.json"]?.map(\.id) == ["claude-opus-5-5"])
        #expect(harness.server.requests(Self.modelsRoute) == 1)

        await session.refreshAccountDetail("a.json")
        #expect(harness.server.requests(Self.modelsRoute) == 1)
        #expect(harness.server.requests(Self.credentialsRoute) == 2)
    }

    @Test func accountDetailPullRefetchesModelsWhenAutomaticRefreshIsOn() async {
        let harness = harnessWithModels()
        let session = harness.makeSession()

        await session.refreshAccountDetail("a.json")
        await session.refreshAccountDetail("a.json")

        #expect(harness.server.requests(Self.modelsRoute) == 2)
    }

    @Test func accountDetailPullIsManualAndClearsTheAuthPause() async {
        let harness = harnessWithModels()
        harness.server.keyAccepted = false
        let session = harness.makeSession()
        await session.refresh(.accounts, trigger: .automatic)
        #expect(session.isAutomaticRefreshPaused)
        harness.server.keyAccepted = true

        await session.refreshAccountDetail("a.json")

        #expect(!session.isAutomaticRefreshPaused)
        #expect(session.accountsLoaded)
        #expect(session.accountModels["a.json"] != nil)
    }

    @Test func savedSnapshotIsShownWithItsAgeUntilTheServerLoads() async throws {
        let harness = SessionHarness()
        let savedAt = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 - 600).rounded(.down))
        let saved = HeadroomSnapshot(
            serverID: harness.profile.id, serverName: harness.profile.name, isDemo: false, generatedAt: savedAt, source: .passiveObservations,
            providers: [],
            poolAccounts: [PoolAccount(provider: "claude", availability: .available, bars: [QuotaBar(id: "weekly_all", usedPercent: 25)])]
        )
        harness.store.saveSnapshot(saved)
        let session = harness.makeSession()
        session.refreshesAutomatically = false

        let before = session.quotaOverview(at: .now)
        #expect(before.savedAt == savedAt)
        #expect(before.pools.first?.window(.weekly)?.remainingPercent == 75)
        #expect(before.headroom.first?.headroomPercent == 75)
        #expect(harness.server.log.isEmpty)

        await session.refresh(.accounts, trigger: .manual)
        #expect(session.quotaOverview(at: .now).savedAt == nil)
    }
}
