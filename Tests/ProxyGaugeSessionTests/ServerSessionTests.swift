import Foundation
import Testing
import ProxyGaugeCore
import ProxyGaugeStore
@testable import ProxyGaugeSession

@MainActor
@Suite("Server session ordering and auth outcomes")
struct ServerSessionTests {
    static let credentials = "GET /v8/management/credentials"
    static let counters = "GET /v8/management/observability/usage/api-keys"
    static let policies = "GET /v8/management/client-key-policies"
    static let routing = "GET /v8/management/config/routing/strategy"
    static let routingWrite = "PUT /v8/management/config/routing/strategy"
    static let disable = "PATCH /v8/management/credentials/status"
    static let usageReport = "GET /v8/management/usage/client-keys"

    @Test func mutationRejectedAfterAnOlderRefreshSucceededStaysPaused() async throws {
        let harness = SessionHarness()
        let session = harness.makeSession()
        await session.refresh(.accounts, trigger: .automatic)
        let credential = try #require(session.credentials.first)

        let countersHeld = Gate()
        harness.server.heldAfterAnswer[Self.counters] = countersHeld
        let olderRefresh = Task { await session.refresh(.accounts, trigger: .automatic) }
        await settle()
        harness.server.keyAccepted = false
        let mutation = Task { try await session.setDisabled(true, credential: credential) }
        await settle()
        #expect(harness.server.requests(Self.disable) == 0)

        countersHeld.open()
        await olderRefresh.value
        await #expect(throws: APIError.unauthorized("invalid management key")) { try await mutation.value }

        #expect(session.pauseReason == .keyRejected)
        #expect(harness.storedPause() == .keyRejected)
        let log = harness.server.log
        #expect(try #require(log.lastIndex(of: "answered \(Self.counters)")) < #require(log.firstIndex(of: Self.disable)))
        let before = harness.server.log.count
        await session.refresh(.accounts, trigger: .automatic)
        #expect(harness.server.log.count == before)
    }

    @Test(arguments: [false, true])
    func rejectedRoutingReadBackPausesAutomaticRefresh(writeConflicts: Bool) async {
        let harness = SessionHarness()
        let session = harness.makeSession()
        await session.refresh(.settings, trigger: .automatic)
        #expect(session.routing?.strategy == "round-robin")
        harness.server.overrides[Self.routing] = FakeServer.rejection
        let expectedETag = writeConflicts ? "\"stale\"" : harness.server.etag

        await #expect(throws: APIError.unauthorized("invalid management key")) {
            try await session.setRoutingStrategy("fill-first", expectedETag: expectedETag)
        }

        #expect(session.pauseReason == .keyRejected)
        #expect(session.authError == .unauthorized("invalid management key"))
        let before = harness.server.log.count
        await session.refresh(.settings, trigger: .automatic)
        #expect(harness.server.log.count == before)
    }

    @Test func routingReadBackThatIsUnavailableKeepsTheWrittenValue() async throws {
        let harness = SessionHarness()
        let session = harness.makeSession()
        await session.refresh(.settings, trigger: .automatic)
        harness.server.overrides[Self.routing] = HTTPResponse(statusCode: 503, body: Data())

        try await session.setRoutingStrategy("fill-first", expectedETag: harness.server.etag)

        #expect(session.routing == RoutingStrategySetting(strategy: "fill-first", isExplicit: true, etag: nil))
        #expect(!session.isAutomaticRefreshPaused)
    }

    @Test func settingsRefreshStartedBeforeARoutingWriteCannotRestoreTheOldValue() async throws {
        let harness = SessionHarness()
        let session = harness.makeSession()
        await session.refresh(.settings, trigger: .automatic)
        let pickedETag = try #require(session.routing?.etag)

        let policiesHeld = Gate()
        harness.server.heldAfterAnswer[Self.policies] = policiesHeld
        let olderRefresh = Task { await session.refresh(.settings, trigger: .automatic) }
        await settle()
        let write = Task { try await session.setRoutingStrategy("fill-first", expectedETag: pickedETag) }
        await settle()
        #expect(harness.server.requests(Self.routingWrite) == 0)

        policiesHeld.open()
        await olderRefresh.value
        try await write.value

        #expect(session.routing?.strategy == "fill-first")
        #expect(session.routing?.etag == harness.server.etag)
    }

    @Test func usageReportFailureStillPublishesTheAccountsAndCounters() async {
        let harness = SessionHarness()
        harness.server.overrides[Self.usageReport] = HTTPResponse(statusCode: 503, body: Data(#"{"error":"usage store unavailable"}"#.utf8))
        let session = harness.makeSession()

        await session.refresh(.usage, trigger: .automatic)

        #expect(harness.server.requests(Self.credentials) == 1)
        #expect(harness.server.requests(Self.counters) == 1)
        #expect(session.accountsLoaded)
        #expect(session.credentials.count == 1)
        #expect(session.keyCountersError == nil)
        #expect(!session.tokenUsageLoaded)
        #expect(session.failure(for: .usage) == .server(status: 503, message: "usage store unavailable"))
        #expect(session.failure(for: .accounts) == nil)
        #expect(!session.isAutomaticRefreshPaused)
    }

    @Test func failedSectionStaysUnavailableWhenAnotherSectionSucceeds() async {
        let harness = SessionHarness()
        harness.server.overrides[Self.routing] = HTTPResponse(statusCode: 500, body: Data())
        let session = harness.makeSession()

        await session.refresh(.settings, trigger: .automatic)
        #expect(session.loadPhase(for: .settings, loaded: session.routingLoaded) == .unavailable)
        await session.refresh(.accounts, trigger: .automatic)

        #expect(session.loadPhase(for: .settings, loaded: session.routingLoaded) == .unavailable)
        #expect(session.loadPhase(for: .accounts, loaded: session.accountsLoaded) == .loaded)
        #expect(session.failure(for: .accounts) == nil)
    }

    @Test func accountModelFailureOnlyMarksThatAccount() async {
        let harness = SessionHarness()
        let session = harness.makeSession()
        await session.refresh(.accounts, trigger: .automatic)

        await session.refresh(.accountModels("a.json"), trigger: .automatic)

        #expect(session.accountModelsFailed == ["a.json"])
        #expect(session.failure(for: .accounts) == nil)
        #expect(session.scopeErrors.isEmpty)
        #expect(!session.isAutomaticRefreshPaused)
    }

    @Test func successfulMutationClearsThePause() async throws {
        let harness = SessionHarness()
        let session = harness.makeSession()
        await session.refresh(.accounts, trigger: .automatic)
        let credential = try #require(session.credentials.first)
        harness.server.keyAccepted = false
        await session.refresh(.accounts, trigger: .manual)
        #expect(session.pauseReason == .keyRejected)

        harness.server.keyAccepted = true
        try await session.setDisabled(true, credential: credential)

        #expect(!session.isAutomaticRefreshPaused)
        #expect(session.authError == nil)
        #expect(harness.storedPause() == nil)
    }

    @Test func ipBanIsStoredAsABanNotAsARejectedKey() async {
        let harness = SessionHarness()
        harness.server.overrides[Self.credentials] = HTTPResponse(statusCode: 403, body: Data(#"{"error":"IP banned due to too many failed attempts. Try again in 29m12s"}"#.utf8))
        let session = harness.makeSession()

        await session.refresh(.accounts, trigger: .automatic)

        #expect(session.pauseReason == .ipBanned)
        #expect(harness.storedPause() == .ipBanned)
    }

    @Test func serverSavedAfterARejectedCheckStartsPaused() async {
        let harness = SessionHarness()
        harness.store.resetAuthFailureLatch(for: harness.profile.id, pausedBy: .keyRejected)
        let session = harness.makeSession()

        await session.refresh(.accounts, trigger: .automatic)
        #expect(harness.server.log.isEmpty)
        #expect(session.pauseReason == .keyRejected)

        await session.refresh(.accounts, trigger: .manual)
        #expect(harness.server.requests(Self.credentials) == 1)
        #expect(!session.isAutomaticRefreshPaused)
    }

    @Test func lateWidgetWriteForAnOldGenerationDoesNotPauseTheNewSession() async {
        let harness = SessionHarness()
        let widgetGeneration = harness.store.authGeneration(for: harness.profile.id)
        harness.store.resetAuthFailureLatch(for: harness.profile.id)
        harness.store.saveAuthFailureLatch(AuthFailureLatch(pauseReason: .keyRejected), for: harness.profile.id, generation: widgetGeneration)
        let session = harness.makeSession()

        await session.refresh(.accounts, trigger: .automatic)

        #expect(harness.server.requests(Self.credentials) == 1)
        #expect(!session.isAutomaticRefreshPaused)
    }

    @Test func widgetPauseForTheCurrentGenerationStopsTheAppLoop() async {
        let harness = SessionHarness()
        let session = harness.makeSession()
        harness.store.saveAuthFailureLatch(AuthFailureLatch(pauseReason: .ipBanned), for: harness.profile.id, generation: harness.store.authGeneration(for: harness.profile.id))

        await session.refresh(.accounts, trigger: .automatic)

        #expect(harness.server.log.isEmpty)
        #expect(session.pauseReason == .ipBanned)
    }

    @Test func cancelledRootRefreshWaitingBehindAnotherNeverSendsRequests() async {
        let harness = SessionHarness()
        let session = harness.makeSession()
        let countersHeld = Gate()
        harness.server.heldAfterAnswer[Self.counters] = countersHeld
        let accounts = Task { await session.refresh(.accounts, trigger: .automatic) }
        await settle()
        let obsolete = Task { await session.refresh(.settings, trigger: .automatic, dropIfCancelled: true) }
        await settle()
        obsolete.cancel()
        countersHeld.open()
        await accounts.value
        await obsolete.value

        #expect(harness.server.requests(Self.routing) == 0)
        #expect(session.loadPhase(for: .settings, loaded: session.routingLoaded) == .loading)
    }
}
