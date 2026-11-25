import Foundation
import ProxyGaugeCore
import Testing
@testable import ProxyGaugeSession

@Suite("Surface provider approvals and API reload outcomes")
@MainActor
struct SurfaceRefreshRegressionTests {
    private typealias Fixtures = ProviderRefreshSessionTests

    private func setup(_ credentials: String) -> (SessionHarness, ServerSession) {
        let fixtures = Fixtures()
        let harness = fixtures.harness()
        harness.server.overrides[Fixtures.credentialsRoute] = HTTPResponse(statusCode: 200, body: Data(credentials.utf8))
        return (harness, fixtures.session(harness))
    }

    @Test func googleApprovalFromTheReportTargetsOnlyTheRequestedStableID() async throws {
        let (harness, session) = setup(#"{"files":[{"name":"a.json","auth_index":"idx-a","provider":"antigravity","type":"antigravity","project_id":"p1"},{"name":"b.json","auth_index":"idx-b","provider":"antigravity","type":"antigravity","project_id":"p2"}]}"#)
        await session.refresh(.accounts, trigger: .manual)
        let account = try #require(session.credentials.first)
        #expect(account.id == "idx-a")
        #expect(account.stableID == "a.json")
        await session.refreshProviderFromSurface([account.id])
        let report = try #require(session.providerRefreshReport)
        #expect(report.entries.map(\.id) == ["a.json"])
        #expect(report.needsConsent)
        #expect(harness.server.requests(Fixtures.apiCallRoute) == 0)
        #expect(session.providerApprovalPlan(for: report, now: .now).readyCount == 1)

        await session.approveProviderRefresh(report)
        #expect(harness.server.requests(Fixtures.apiCallRoute) > 0)
        #expect(session.providerRefreshReport?.entries.map(\.id) == ["a.json"])
        #expect(session.providerApprovalPlan(for: report, now: .now).isEmpty)
        #expect(session.providerCheckStates["b.json"] == nil)
    }

    @Test func paidKeyApprovalFromTheReportDoesNotWaitForANewCheck() async throws {
        let (harness, session) = setup(#"{"files":[{"name":"xai.json","auth_index":"idx-xai","provider":"xai","type":"xai"}]}"#)
        harness.server.overrides[Fixtures.apiCallRoute] = Fixtures.envelope(200, "{}")
        await session.refresh(.accounts, trigger: .manual)
        await session.refreshProviderFromSurface()
        let report = try #require(session.providerRefreshReport)
        #expect(report.needsConsent)
        #expect(harness.server.requests(Fixtures.apiCallRoute) == 2)
        let plan = session.providerApprovalPlan(for: report, now: .now)
        #expect(plan.groups.first?.requests == [.paidKeyCheck])
        #expect(plan.maximumRequests == 2)

        await session.approveProviderRefresh(report)
        #expect(harness.server.requests(Fixtures.apiCallRoute) == 4)
        #expect(session.activeQuotas["xai.json"]?.note == .paidKeyAnswered)
        await session.approveProviderRefresh(report)
        #expect(harness.server.requests(Fixtures.apiCallRoute) == 4)
    }

    @Test func progressExcludesWaitingAndSkippedCredentials() async throws {
        let (harness, session) = setup(#"{"files":[{"name":"a.json","auth_index":"1","provider":"claude","type":"claude"},{"name":"b.json","auth_index":"2","provider":"claude","type":"claude"},{"name":"c.json","auth_index":"3","provider":"unknown","type":"unknown"}]}"#)
        await session.refresh(.accounts, trigger: .manual)
        await session.refreshProviderFromSurface(["1"])
        let before = harness.server.requests(Fixtures.apiCallRoute)
        let gate = Gate()
        harness.server.heldAfterAnswer[Fixtures.apiCallRoute] = gate
        let refresh = Task { await session.refreshProviderFromSurface() }
        await eventually { harness.server.requests(Fixtures.apiCallRoute) > before }
        #expect(session.providerRefreshProgress == ProviderRefreshProgress(completed: 0, total: 1))
        gate.open()
        await refresh.value
        #expect(session.providerRefreshReport?.entries.count == 3)
        #expect(session.providerRefreshReport?.checked == 1)
    }

    @Test func reloadingAccountDetailReportsFailureEvenWithAnOlderModelList() async {
        let harness = SessionHarness()
        let session = harness.makeSession()
        session.refreshesAutomatically = false
        let models = "GET /v8/management/credentials/models"
        let scope = RefreshScope.accountDetail("a.json")
        harness.server.overrides[models] = HTTPResponse(statusCode: 200, body: Data(#"{"models":[]}"#.utf8))
        #expect(await session.reloadFromAPI(scope) { _ in })
        let prior = session.lastRefresh(for: scope)

        harness.server.overrides[models] = HTTPResponse(statusCode: 503, body: Data())
        #expect(await !session.reloadFromAPI(scope) { _ in })
        #expect(session.lastRefresh(for: scope) != prior)
        #expect(session.accountModels["a.json"] == [])
        #expect(session.accountModelsFailed.contains("a.json"))
        #expect(harness.server.requests(models) == 2)
    }
}
