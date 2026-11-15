import Foundation
import ProxyGaugeCore
import ProxyGaugeStore
import Testing
@testable import ProxyGaugeSession

@Suite("Provider limit refresh in a session")
@MainActor
struct ProviderRefreshSessionTests {
    static let apiCallRoute = "POST /v8/management/requests/api-call"
    static let credentialsRoute = "GET /v8/management/credentials"

    static func envelope(_ status: Int, _ body: String) -> HTTPResponse {
        let payload: [String: Any] = ["status_code": status, "header": [String: [String]](), "body": body]
        return HTTPResponse(statusCode: 200, body: try! JSONSerialization.data(withJSONObject: payload))
    }

    static let usage = envelope(200, #"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":70,"resets_at":"2099-01-05T00:00:00Z"}}"#)

    func harness() -> SessionHarness {
        let harness = SessionHarness()
        harness.server.overrides[Self.apiCallRoute] = Self.usage
        harness.server.overrides[Self.credentialsRoute] = HTTPResponse(statusCode: 200, body: Data(#"{"files":[{"name":"a.json","auth_index":"1","provider":"claude","type":"claude"},{"name":"b.json","auth_index":"2","provider":"claude","type":"claude"},{"name":"k.json","auth_index":"3","provider":"kimi","type":"kimi"}]}"#.utf8))
        return harness
    }

    func session(_ harness: SessionHarness, profile: ServerProfile? = nil, refreshesLimitsAutomatically: Bool = false) -> ServerSession {
        ServerSession(
            profile: profile ?? harness.profile,
            secrets: harness.secrets,
            latchStore: harness.store,
            transport: FakeServerTransport(server: harness.server),
            coordinator: ActiveRefreshCoordinator(store: harness.store, pause: { _ in }),
            refreshesLimitsAutomatically: refreshesLimitsAutomatically
        )
    }

    func startAutomaticLoop(_ session: ServerSession) -> Task<Void, Never> {
        Task { await session.runAutomaticLimitsRefresh(every: .seconds(3_600)) }
    }

    func runOneAutomaticTick(_ session: ServerSession) async {
        let before = session.lastLimitsResults
        let loop = startAutomaticLoop(session)
        await eventually { session.lastLimitsResults != before || !session.refreshingLimits.isEmpty }
        await eventually { session.refreshingLimits.isEmpty }
        loop.cancel()
        await loop.value
    }

    @Test func automaticProviderRefreshIsOffByDefault() async {
        #expect(!StoredSettings().refreshesLimitsFromProviders(UUID()))
        #expect(StoredSettings().providerRefreshInterval(UUID()) == 30 * 60)
        let harness = harness()
        let session = session(harness)
        await session.refresh(.accounts, trigger: .manual)

        let loop = startAutomaticLoop(session)
        await settle()
        loop.cancel()
        await loop.value

        #expect(harness.server.requests(Self.apiCallRoute) == 0)
    }

    @Test func automaticProviderRefreshNeedsTheVisibleLoop() async {
        let harness = harness()
        let session = session(harness, refreshesLimitsAutomatically: true)
        await session.refresh(.accounts, trigger: .manual)

        await session.refreshLimits(trigger: .automatic, origin: .visibleApp)
        await session.refreshLimits(trigger: .automatic, origin: .menuBar)

        #expect(harness.server.requests(Self.apiCallRoute) == 0)
    }

    @Test func automaticProviderRefreshAlsoObeysTheAutomaticRefreshSwitch() async {
        let harness = harness()
        let session = session(harness, refreshesLimitsAutomatically: true)
        await session.refresh(.accounts, trigger: .manual)
        session.refreshesAutomatically = false

        let loop = startAutomaticLoop(session)
        await settle()
        loop.cancel()
        await loop.value
        #expect(harness.server.requests(Self.apiCallRoute) == 0)

        session.refreshesAutomatically = true
        await runOneAutomaticTick(session)
        #expect(harness.server.requests(Self.apiCallRoute) > 0)
    }

    @Test func cancellingTheAutomaticLoopMidBatchStopsFurtherSends() async {
        let harness = harness()
        let session = session(harness, refreshesLimitsAutomatically: true)
        await session.refresh(.accounts, trigger: .manual)
        let gate = Gate()
        harness.server.heldAfterAnswer[Self.apiCallRoute] = gate

        let loop = startAutomaticLoop(session)
        await eventually { harness.server.requests(Self.apiCallRoute) == 1 }
        loop.cancel()
        gate.open()
        await loop.value
        await eventually { session.refreshingLimits.isEmpty }

        #expect(harness.server.requests(Self.apiCallRoute) == 1)
    }

    @Test func turningAutomaticProviderRefreshOffMidBatchStopsFurtherSends() async {
        let harness = harness()
        let session = session(harness, refreshesLimitsAutomatically: true)
        await session.refresh(.accounts, trigger: .manual)
        let gate = Gate()
        harness.server.heldAfterAnswer[Self.apiCallRoute] = gate

        let loop = startAutomaticLoop(session)
        await eventually { harness.server.requests(Self.apiCallRoute) == 1 }
        session.refreshesLimitsAutomatically = false
        gate.open()
        await eventually { !session.lastLimitsResults.isEmpty }
        loop.cancel()
        await loop.value

        #expect(harness.server.requests(Self.apiCallRoute) == 1)
    }

    @Test func manualRefreshMergesProviderDataAndPersistsIt() async throws {
        let harness = harness()
        let session = session(harness)
        session.onHeadroomUpdate = { harness.store.saveSnapshot($0) }

        await session.refreshLimits(["1"], trigger: .manual, origin: .visibleApp)

        let account = try #require(session.accountSummaries.first { $0.id == "1" })
        #expect(account.bar("weekly_all")?.usedPercent == 70)
        #expect(account.bar("weekly_all")?.source == .provider)
        #expect(account.providerCheck != nil)
        #expect(harness.store.snapshot(for: harness.profile.id)?.poolAccounts.contains { $0.bars.contains { $0.source == .provider } } == true)

        let relaunched = self.session(harness)
        #expect(relaunched.activeQuotas["a.json"]?.windows.count == 2)
        #expect(relaunched.providerCheckStates["a.json"]?.lastSuccessAt != nil)
    }

    @Test func throttleStateFollowsTheAuthFileWhenItsAuthIndexChanges() async throws {
        let harness = harness()
        let session = session(harness)
        await session.refreshLimits(["1"], trigger: .manual, origin: .visibleApp)
        harness.server.overrides[Self.credentialsRoute] = HTTPResponse(statusCode: 200, body: Data(#"{"files":[{"name":"a.json","auth_index":"91","provider":"claude","type":"claude"}]}"#.utf8))

        await session.refresh(.accounts, trigger: .manual)

        let plan = session.limitsRefreshPlan(for: ["91"])
        #expect(plan.isEmpty)
        #expect(plan.waiting.first?.because == .recentlyChecked)
        #expect(session.accountSummaries.first?.providerCheck != nil)
    }

    @Test func twoProfilesForOneProxyAndAReAddedServerShareWaitsAndReadings() async throws {
        let harness = harness()
        let first = session(harness)
        await first.refreshLimits(["1"], trigger: .manual, origin: .visibleApp)
        harness.store.forgetServer(harness.profile.id)

        let readded = ServerProfile(name: "Home again", baseURL: URL(string: "HTTP://192.168.1.20:8317/")!, authMode: .management)
        try harness.secrets.setSecret("test-key", for: readded.id)
        let second = session(harness, profile: readded)
        await second.refresh(.accounts, trigger: .manual)

        let plan = second.limitsRefreshPlan(for: ["1"])
        #expect(plan.isEmpty)
        #expect(plan.waiting.map(\.credentialID) == ["a.json"])
        #expect(second.activeQuotas["a.json"]?.windows.count == 2)
    }

    @Test func managementRejectionPausesAfterOneAttempt() async {
        let harness = harness()
        let session = session(harness)
        await session.refresh(.accounts, trigger: .manual)
        harness.server.overrides[Self.apiCallRoute] = FakeServer.rejection

        await session.refreshLimits(trigger: .manual, origin: .visibleApp)

        #expect(harness.server.requests(Self.apiCallRoute) == 1)
        #expect(session.pauseReason == .keyRejected)
        #expect(harness.storedPause() == .keyRejected)

        await session.refreshLimits(trigger: .automatic, origin: .visibleApp)
        await session.refresh(.accounts, trigger: .automatic)
        #expect(harness.server.requests(Self.apiCallRoute) == 1)
    }

    @Test func aLateProviderSuccessKeepsANewerAuthPause() async {
        let harness = harness()
        harness.server.overrides[Self.credentialsRoute] = HTTPResponse(statusCode: 200, body: Data(#"{"files":[{"name":"d.json","auth_index":"4","provider":"devin","type":"devin"}]}"#.utf8))
        harness.server.overrides[Self.apiCallRoute] = Self.envelope(200, #"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":80}}}"#)
        let session = session(harness)
        await session.refresh(.accounts, trigger: .manual)
        let gate = Gate()
        harness.server.heldAfterAnswer[Self.apiCallRoute] = gate

        let refresh = Task { await session.refreshLimits(["4"], trigger: .manual, origin: .visibleApp) }
        await eventually { harness.server.requests(Self.apiCallRoute) == 1 }
        harness.store.saveAuthFailureLatch(AuthFailureLatch(pauseReason: .keyRejected), for: harness.profile.id, generation: harness.store.authGeneration(for: harness.profile.id))

        gate.open()
        await refresh.value

        #expect(session.lastLimitsResults.first.map { if case .refreshed = $0.outcome { true } else { false } } == true)
        #expect(session.pauseReason == .keyRejected)
        #expect(harness.storedPause() == .keyRejected)
    }

    @Test func aLateProviderResultIsNotWrittenIntoADeletedServer() async {
        let harness = harness()
        let session = session(harness)
        await session.refresh(.accounts, trigger: .manual)
        let gate = Gate()
        harness.server.heldAfterAnswer[Self.apiCallRoute] = gate

        let refresh = Task { await session.refreshLimits(["1"], trigger: .manual, origin: .visibleApp) }
        await eventually { harness.server.requests(Self.apiCallRoute) == 1 }
        harness.store.forgetServer(harness.profile.id)
        session.retire()
        gate.open()
        await refresh.value

        #expect(harness.store.activeQuotas(proxy: ActiveRefreshServer.proxyKey(harness.profile.baseURL)).isEmpty)
        let proxy = ActiveRefreshServer.proxyKey(harness.profile.baseURL)
        #expect(harness.store.activeRefreshStates(proxy: proxy)["a.json"]?.lastAttemptAt != nil)
    }

    @Test func waitingOnlyTicksDoNotRestampTheSnapshot() async {
        let harness = harness()
        let session = session(harness, refreshesLimitsAutomatically: true)
        var published: [HeadroomSnapshot] = []
        session.onHeadroomUpdate = { published.append($0) }
        await session.refresh(.accounts, trigger: .manual)
        let afterAccounts = published.count

        await runOneAutomaticTick(session)
        #expect(published.count == afterAccounts + 1)
        #expect(published.last?.generatedAt == published.first?.generatedAt)

        await runOneAutomaticTick(session)
        #expect(published.count == afterAccounts + 1)
        #expect(session.lastLimitsResults.allSatisfy { if case .waiting = $0.outcome { true } else { false } })
    }

    @Test func accountDetailStopsAfterARejectedKey() async {
        let harness = harness()
        let session = session(harness)
        harness.server.keyAccepted = false

        await session.refreshAccountDetail("a.json")

        #expect(harness.server.requests(Self.credentialsRoute) == 1)
        #expect(harness.server.requests("GET /v8/management/credentials/models") == 0)
        #expect(session.pauseReason == .keyRejected)
    }

    @Test func nestedRateLimitShowsWhenTheNextTryIsAllowed() async throws {
        let harness = harness()
        harness.server.overrides[Self.apiCallRoute] = Self.envelope(429, #"{"error":"rate_limited"}"#)
        let session = session(harness)

        await session.refreshLimits(["1"], trigger: .manual, origin: .visibleApp)

        let state = try #require(session.providerCheckStates["a.json"])
        #expect(state.isRateLimited(at: .now))
        #expect(session.pauseReason == nil)
        let plan = session.limitsRefreshPlan(for: ["1"])
        #expect(plan.isEmpty)
        #expect(plan.waiting.first?.because == .rateLimited)
    }

    @Test func clientKeysCannotRefreshProviderLimits() async {
        let harness = SessionHarness()
        let profile = ServerProfile(name: "Client", baseURL: harness.profile.baseURL, authMode: .clientKey)
        let session = ServerSession(profile: profile, secrets: harness.secrets, latchStore: harness.store, transport: FakeServerTransport(server: harness.server), coordinator: ActiveRefreshCoordinator(store: harness.store))
        #expect(!session.supportsLimitsRefresh)
        await session.refreshLimits(trigger: .manual, origin: .visibleApp)
        #expect(harness.server.requests(Self.apiCallRoute) == 0)
    }
}

@MainActor
func eventually(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
