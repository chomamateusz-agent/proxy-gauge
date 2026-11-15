import Foundation
import ProxyGaugeCore
import ProxyGaugeStore
import Testing
@testable import ProxyGaugeSession

@Suite("Provider checks admitted at send time and shared per proxy")
@MainActor
struct SharedProviderChecksTests {
    static let apiCall = ProviderRefreshSessionTests.apiCallRoute
    static let credentials = ProviderRefreshSessionTests.credentialsRoute

    let suite = ProviderRefreshSessionTests()

    func letQueuedRequestsLineUp() async {
        await settle()
        try? await Task.sleep(for: .milliseconds(30))
    }

    func queueAnAutomaticCheckBehindAHeldRead(_ harness: SessionHarness, _ session: ServerSession) async -> (read: Task<Void, Never>, loop: Task<Void, Never>, held: Gate) {
        await session.refresh(.accounts, trigger: .manual)
        let held = Gate()
        harness.server.heldAfterAnswer[Self.credentials] = held
        let read = Task { await session.refresh(.accounts, trigger: .automatic) }
        await eventually { harness.server.requests(Self.credentials) == 2 }
        let loop = suite.startAutomaticLoop(session)
        await eventually { !session.refreshingLimits.isEmpty }
        await letQueuedRequestsLineUp()
        return (read, loop, held)
    }

    @Test func anAutomaticCheckWaitingForItsTurnIsNotSentAfterTheSwitchIsTurnedOff() async {
        let harness = suite.harness()
        let session = suite.session(harness, refreshesLimitsAutomatically: true)
        let queued = await queueAnAutomaticCheckBehindAHeldRead(harness, session)

        session.refreshesLimitsAutomatically = false
        queued.held.open()
        await queued.read.value
        await eventually { session.refreshingLimits.isEmpty }
        queued.loop.cancel()
        await queued.loop.value

        #expect(harness.server.requests(Self.apiCall) == 0)
        #expect(session.providerCheckStates.isEmpty)
    }

    @Test func anAutomaticCheckWaitingForItsTurnIsNotSentAfterItsLoopIsCancelled() async {
        let harness = suite.harness()
        let session = suite.session(harness, refreshesLimitsAutomatically: true)
        let queued = await queueAnAutomaticCheckBehindAHeldRead(harness, session)

        queued.loop.cancel()
        queued.held.open()
        await queued.read.value
        await queued.loop.value
        await eventually { session.refreshingLimits.isEmpty }

        #expect(harness.server.requests(Self.apiCall) == 0)
        #expect(session.providerCheckStates.isEmpty)
    }

    func twoEntriesOfOneProxy(_ harness: SessionHarness, secondServer: FakeServer? = nil) throws -> (ServerSession, ServerSession) {
        let second = ServerProfile(name: "Home, second key", baseURL: harness.profile.baseURL, authMode: .management)
        try harness.secrets.setSecret("second-test-key", for: second.id)
        let coordinator = ActiveRefreshCoordinator(store: harness.store, pause: { _ in })
        let first = ServerSession(profile: harness.profile, secrets: harness.secrets, latchStore: harness.store, transport: FakeServerTransport(server: harness.server), coordinator: coordinator)
        let other = ServerSession(profile: second, secrets: harness.secrets, latchStore: harness.store, transport: FakeServerTransport(server: secondServer ?? harness.server), coordinator: coordinator)
        return (first, other)
    }

    @Test func aValidKeyJoiningACheckTheProxyRefusedRunsItsOwnCheckAtOnce() async throws {
        let harness = suite.harness()
        let validServer = FakeServer()
        validServer.overrides = harness.server.overrides
        let (stale, valid) = try twoEntriesOfOneProxy(harness, secondServer: validServer)
        await stale.refresh(.accounts, trigger: .manual)
        await valid.refresh(.accounts, trigger: .manual)
        let rejectionHeld = Gate()
        harness.server.overrides[Self.apiCall] = FakeServer.rejection
        harness.server.heldAfterAnswer[Self.apiCall] = rejectionHeld

        let first = Task { await stale.refreshLimits(["1"], trigger: .manual, origin: .visibleApp) }
        await eventually { harness.server.requests(Self.apiCall) == 1 }
        let joined = Task { await valid.refreshLimits(["1"], trigger: .manual, origin: .visibleApp) }
        await letQueuedRequestsLineUp()
        rejectionHeld.open()
        await first.value
        await joined.value

        #expect(stale.pauseReason == .keyRejected)
        #expect(valid.pauseReason == nil)
        #expect(valid.lastLimitsResults.first?.outcome.isRefreshed == true)
        #expect(validServer.requests(Self.apiCall) == 3)
        let account = try #require(valid.accountSummaries.first { $0.id == "1" })
        #expect(account.bar("weekly_all")?.source == .provider)
    }

    @Test func anotherEntryOfTheProxyPublishesNewReadingsWhenItLoadsAccounts() async throws {
        let harness = suite.harness()
        let (first, second) = try twoEntriesOfOneProxy(harness)
        var published: [HeadroomSnapshot] = []
        second.onHeadroomUpdate = { published.append($0) }
        await first.refresh(.accounts, trigger: .manual)
        await second.refresh(.accounts, trigger: .manual)

        await first.refreshLimits(["1"], trigger: .manual, origin: .visibleApp)
        await second.refresh(.accounts, trigger: .manual)

        let account = try #require(second.accountSummaries.first { $0.id == "1" })
        #expect(account.bar("weekly_all")?.source == .provider)
        let snapshot = try #require(published.last)
        #expect(snapshot.poolAccounts.contains { $0.bars.contains { $0.source == .provider } })
        let now = Date.now
        #expect(second.limitsRefreshPlan(for: ["1"], now: now) == first.limitsRefreshPlan(for: ["1"], now: now))
    }

    @Test func anotherEntryOfTheProxyShowsNewReadingsWhenItBecomesVisible() async throws {
        let harness = suite.harness()
        let (first, second) = try twoEntriesOfOneProxy(harness)
        await first.refresh(.accounts, trigger: .manual)
        await second.refresh(.accounts, trigger: .manual)

        await first.refreshLimits(["1"], trigger: .manual, origin: .visibleApp)
        second.reloadProviderChecks()

        let account = try #require(second.accountSummaries.first { $0.id == "1" })
        #expect(account.bar("weekly_all")?.source == .provider)
        #expect(second.providerCheckStates == first.providerCheckStates)
    }
}
