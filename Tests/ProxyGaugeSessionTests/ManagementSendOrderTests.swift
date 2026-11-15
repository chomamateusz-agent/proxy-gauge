import Foundation
import ProxyGaugeCore
import ProxyGaugeStore
import Testing
@testable import ProxyGaugeSession

@Suite("One management request at a time per server")
@MainActor
struct ManagementSendOrderTests {
    static let apiCall = ProviderRefreshSessionTests.apiCallRoute
    static let credentials = ProviderRefreshSessionTests.credentialsRoute
    static let counters = "GET /v8/management/observability/usage/api-keys"
    static let disable = "PATCH /v8/management/credentials/status"
    static let models = "GET /v8/management/credentials/models"

    let suite = ProviderRefreshSessionTests()

    func letQueuedRequestsLineUp() async {
        await settle()
        try? await Task.sleep(for: .milliseconds(30))
    }

    @Test func anActiveRejectionStopsAPassiveRefreshAlreadyUnderway() async {
        let harness = suite.harness()
        let session = suite.session(harness)
        await session.refresh(.accounts, trigger: .manual)
        let countersBefore = harness.server.requests(Self.counters)
        let credentialsHeld = Gate()
        harness.server.heldAfterAnswer[Self.credentials] = credentialsHeld
        harness.server.overrides[Self.apiCall] = FakeServer.rejection

        let passive = Task { await session.refresh(.accounts, trigger: .automatic) }
        await eventually { harness.server.requests(Self.credentials) == 2 }
        let active = Task { await session.refreshLimits(["1"], trigger: .manual, origin: .visibleApp) }
        await letQueuedRequestsLineUp()
        credentialsHeld.open()
        await passive.value
        await active.value

        #expect(harness.server.requests(Self.apiCall) == 1)
        #expect(harness.server.requests(Self.counters) == countersBefore)
        #expect(session.pauseReason == .keyRejected)
        #expect(harness.storedPause() == .keyRejected)
    }

    @Test func anActiveRejectionStopsTheReloadAfterASuccessfulChange() async throws {
        let harness = suite.harness()
        let session = suite.session(harness)
        await session.refresh(.accounts, trigger: .manual)
        let credential = try #require(session.credentials.first)
        let changeHeld = Gate()
        harness.server.heldAfterAnswer[Self.disable] = changeHeld
        harness.server.overrides[Self.apiCall] = FakeServer.rejection

        let change = Task { try await session.setDisabled(true, credential: credential) }
        await eventually { harness.server.requests(Self.disable) == 1 }
        let credentialsBefore = harness.server.requests(Self.credentials)
        let active = Task { await session.refreshLimits(["1"], trigger: .manual, origin: .visibleApp) }
        await letQueuedRequestsLineUp()
        changeHeld.open()
        try await change.value
        await active.value

        #expect(harness.server.requests(Self.apiCall) == 1)
        #expect(harness.server.requests(Self.credentials) == credentialsBefore)
        #expect(session.pauseReason == .keyRejected)
    }

    @Test func aProviderCheckQueuedBehindARejectedReadIsNotSentAndLeavesNoWait() async throws {
        let harness = suite.harness()
        let session = suite.session(harness)
        await session.refresh(.accounts, trigger: .manual)
        let credentialsHeld = Gate()
        harness.server.heldAfterAnswer[Self.credentials] = credentialsHeld
        harness.server.overrides[Self.credentials] = FakeServer.rejection

        let passive = Task { await session.refresh(.accounts, trigger: .automatic) }
        await eventually { harness.server.requests(Self.credentials) == 2 }
        let active = Task { await session.refreshLimits(["1"], trigger: .manual, origin: .visibleApp) }
        await letQueuedRequestsLineUp()
        credentialsHeld.open()
        await passive.value
        await active.value

        #expect(harness.server.requests(Self.apiCall) == 0)
        #expect(session.lastLimitsResults.first?.outcome == .notSent)
        #expect(session.providerCheckStates["a.json"] == nil)
        #expect(session.pauseReason == .keyRejected)
    }

    @Test func twoProfilesOfOneProxyBothGetTheSharedReading() async throws {
        let harness = suite.harness()
        let second = ServerProfile(name: "Home, second key", baseURL: harness.profile.baseURL, authMode: .management)
        try harness.secrets.setSecret("test-key", for: second.id)
        let coordinator = ActiveRefreshCoordinator(store: harness.store, pause: { _ in })
        let sessions = [harness.profile, second].map { profile in
            ServerSession(profile: profile, secrets: harness.secrets, latchStore: harness.store, transport: FakeServerTransport(server: harness.server), coordinator: coordinator)
        }
        for session in sessions { await session.refresh(.accounts, trigger: .manual) }
        let answerHeld = Gate()
        harness.server.heldAfterAnswer[Self.apiCall] = answerHeld

        let first = Task { await sessions[0].refreshLimits(["1"], trigger: .manual, origin: .visibleApp) }
        await eventually { harness.server.requests(Self.apiCall) == 1 }
        let joined = Task { await sessions[1].refreshLimits(["1"], trigger: .manual, origin: .visibleApp) }
        await letQueuedRequestsLineUp()
        answerHeld.open()
        await first.value
        let oneManualClaudeCheck = harness.server.requests(Self.apiCall)
        await joined.value

        #expect(oneManualClaudeCheck == 3)
        #expect(harness.server.requests(Self.apiCall) == oneManualClaudeCheck)
        for session in sessions {
            #expect(session.lastLimitsResults.first?.outcome.isRefreshed == true)
            let account = try #require(session.accountSummaries.first { $0.id == "1" })
            #expect(account.bar("weekly_all")?.source == .provider)
        }
    }

    @Test func freshProviderReadingsJoinANewerSnapshotTheWidgetSaved() async throws {
        let harness = suite.harness()
        let session = suite.session(harness)
        session.onHeadroomUpdate = { harness.store.saveSnapshot($0) }
        await session.refresh(.accounts, trigger: .manual)
        let widgetLoadedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 5).rounded(.up))
        harness.store.saveSnapshot(.management(harness.profile, credentials: session.credentials, generatedAt: widgetLoadedAt, now: .now))

        await session.refreshLimits(["1"], trigger: .manual, origin: .visibleApp)

        let saved = try #require(harness.store.snapshot(for: harness.profile.id))
        #expect(saved.generatedAt == widgetLoadedAt)
        #expect(saved.poolAccounts.contains { $0.bars.contains { $0.source == .provider } })
    }

    @Test func pullingAnAccountPageReloadsTheAccountWhileItsModelsAreLoading() async {
        let harness = SessionHarness()
        let session = harness.makeSession()
        await session.refresh(.accounts, trigger: .manual)
        let modelsHeld = Gate()
        harness.server.heldAfterAnswer[Self.models] = modelsHeld

        let pageOpened = Task { await session.refresh(.accountModels("a.json"), trigger: .automatic) }
        await eventually { harness.server.requests(Self.models) == 1 }
        let credentialsBefore = harness.server.requests(Self.credentials)
        let pull = Task { await session.refreshAccountDetail("a.json") }
        await settle()
        modelsHeld.open()
        await pageOpened.value
        await pull.value

        #expect(harness.server.requests(Self.credentials) == credentialsBefore + 1)
    }
}

extension ActiveRefreshOutcome {
    var isRefreshed: Bool {
        if case .refreshed = self { true } else { false }
    }
}
