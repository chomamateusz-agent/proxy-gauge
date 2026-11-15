import Foundation
import ProxyGaugeCore
import ProxyGaugeStore
import Synchronization
import Testing
@testable import ProxyGaugeSession

final class SecondCheckHeldTransport: HTTPTransport {
    static let devinAccounts = HTTPResponse(statusCode: 200, body: Data(#"{"files":[{"name":"a.json","auth_index":"1","provider":"devin","type":"devin"},{"name":"b.json","auth_index":"2","provider":"devin","type":"devin"}]}"#.utf8))
    static let devinStatus = #"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":80,"weeklyQuotaRemainingPercent":"65","dailyQuotaResetAtUnix":4102444800}}}"#

    let server: FakeServer
    let held: Gate
    private let checks = Mutex(0)

    init(server: FakeServer, held: Gate) {
        self.server = server
        self.held = held
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let isCheck = request.url.path().hasSuffix("/requests/api-call")
        let isSecondCheck = isCheck && checks.withLock { count in
            count += 1
            return count == 2
        }
        guard isSecondCheck else { return await server.respond(to: request) }
        await held.wait()
        return await ProviderRefreshSessionTests.envelope(500, "{}")
    }
}

@Suite("Proxy refusals, the send boundary and widget publication in a session")
@MainActor
struct ProxyRefusalSessionTests {
    static let apiCall = ProviderRefreshSessionTests.apiCallRoute
    static let remoteManagementDisabled = HTTPResponse(statusCode: 403, body: Data(#"{"error":"remote management disabled"}"#.utf8))

    let suite = ProviderRefreshSessionTests()

    @Test func twoAutomaticTicksAfterRemoteManagementWasDisabledSendOneRequest() async {
        let harness = suite.harness()
        let session = suite.session(harness, refreshesLimitsAutomatically: true)
        await session.refresh(.accounts, trigger: .manual)
        harness.server.overrides[Self.apiCall] = Self.remoteManagementDisabled

        await suite.runOneAutomaticTick(session)
        #expect(harness.server.requests(Self.apiCall) == 1)
        await suite.runOneAutomaticTick(session)
        #expect(harness.server.requests(Self.apiCall) == 1)

        #expect(session.limitsRefreshError == .forbidden("remote management disabled"))
        #expect(session.proxyRefusalBackoff != nil)
        #expect(session.proxyRefusalNotice(at: .now) == session.proxyRefusalBackoff.map { .nextAutomaticTry($0.until) })
        #expect(session.pauseReason == nil)
    }

    @Test func theRefusalNoticeAppearsOnlyWhileAutomaticProviderChecksAreOn() async throws {
        let harness = suite.harness()
        let session = suite.session(harness, refreshesLimitsAutomatically: true)
        await session.refresh(.accounts, trigger: .manual)
        harness.server.overrides[Self.apiCall] = Self.remoteManagementDisabled
        await suite.runOneAutomaticTick(session)
        let until = try #require(session.proxyRefusalBackoff?.until)

        #expect(session.proxyRefusalNotice(at: .now) == .nextAutomaticTry(until))
        session.refreshesAutomatically = false
        #expect(session.proxyRefusalNotice(at: .now) == .automaticChecksPaused(until: until))
        session.refreshesAutomatically = true
        session.refreshesLimitsAutomatically = false
        #expect(session.proxyRefusalNotice(at: .now) == nil)
        session.refreshesAutomatically = false
        #expect(session.proxyRefusalNotice(at: .now) == nil)
        session.refreshesLimitsAutomatically = true
        #expect(session.proxyRefusalNotice(at: until) == nil)
    }

    @Test func theSendBoundaryPermitFollowsTheSwitchesAndTheVisibleLoop() async {
        let harness = suite.harness()
        let session = suite.session(harness, refreshesLimitsAutomatically: true)
        #expect(!session.automaticLimitsPermit.isSet)

        let loop = suite.startAutomaticLoop(session)
        await eventually { session.automaticLimitsPermit.isSet }
        #expect(session.automaticLimitsPermit.isSet)
        session.refreshesLimitsAutomatically = false
        #expect(!session.automaticLimitsPermit.isSet)
        session.refreshesLimitsAutomatically = true
        session.refreshesAutomatically = false
        #expect(!session.automaticLimitsPermit.isSet)
        session.refreshesAutomatically = true
        #expect(session.automaticLimitsPermit.isSet)

        loop.cancel()
        await loop.value
        #expect(!session.automaticLimitsPermit.isSet)
    }

    @Test func aReloadDuringABatchDoesNotSwallowTheWidgetPublication() async throws {
        let harness = suite.harness()
        harness.server.overrides[ProviderRefreshSessionTests.credentialsRoute] = SecondCheckHeldTransport.devinAccounts
        harness.server.overrides[Self.apiCall] = ProviderRefreshSessionTests.envelope(200, SecondCheckHeldTransport.devinStatus)
        let held = Gate()
        let session = ServerSession(
            profile: harness.profile,
            secrets: harness.secrets,
            latchStore: harness.store,
            transport: SecondCheckHeldTransport(server: harness.server, held: held),
            coordinator: ActiveRefreshCoordinator(store: harness.store, pause: { _ in })
        )
        var published: [HeadroomSnapshot] = []
        session.onHeadroomUpdate = { published.append($0) }
        await session.refresh(.accounts, trigger: .manual)
        let publishedBeforeBatch = published.count
        let proxy = ActiveRefreshServer.proxyKey(harness.profile.baseURL)

        let batch = Task { await session.refreshLimits(["1", "2"], trigger: .manual, origin: .visibleApp) }
        await eventually { harness.store.activeQuotas(proxy: proxy).count == 1 }
        session.reloadProviderChecks()
        #expect(session.activeQuotas.count == 1)
        held.open()
        await batch.value

        #expect(published.count > publishedBeforeBatch)
        let snapshot = try #require(published.last)
        #expect(snapshot.poolAccounts.contains { $0.bars.contains { $0.source == .provider } })
    }
}
