import Foundation
import Testing
@testable import ProxyGaugeCore

final class HeldTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private let answer: HTTPResponse

    init(answer: HTTPResponse) {
        self.answer = answer
    }

    var sentPaths: [String] { lock.withLock { paths } }

    func open() {
        let released = lock.withLock {
            isOpen = true
            defer { held = [] }
            return held
        }
        released.forEach { $0.resume() }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        await withCheckedContinuation { continuation in
            let passes = lock.withLock {
                paths.append(request.url.path())
                if !isOpen { held.append(continuation) }
                return isOpen
            }
            if passes { continuation.resume() }
        }
        return answer
    }
}

func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("Management send gate")
struct SendGateTests {
    static let rejection = HTTPResponse(statusCode: 401, body: Data(#"{"error":"invalid management key"}"#.utf8))

    @Test func aRejectionStopsTheRequestQueuedBehindItBeforeAnyoneRecordsIt() async throws {
        let transport = HeldTransport(answer: Self.rejection)
        let gate = SendGate()
        let client = ManagementClient(baseURL: testBaseURL, managementKey: "test-key", transport: transport).sending(under: gate.ticket())
        let first = Task { try await client.credentials() }
        await waitUntil { transport.sentPaths.count == 1 }
        let second = Task { try await client.upstreamKeyCounters() }
        try await Task.sleep(for: .milliseconds(30))

        transport.open()

        await #expect(throws: APIError.unauthorized("invalid management key")) { try await first.value }
        await #expect(throws: APIError.pausedBeforeSending(.keyRejected)) { try await second.value }
        #expect(transport.sentPaths == ["/v8/management/credentials"])
    }

    @Test func onlyOneRequestIsInFlightAtATime() async throws {
        let transport = HeldTransport(answer: .json("{}"))
        let gate = SendGate()
        let client = ManagementClient(baseURL: testBaseURL, managementKey: "test-key", transport: transport).sending(under: gate.ticket())
        let reads = (0..<3).map { _ in Task { try await client.upstreamKeyCounters() } }
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.sentPaths.count == 1)

        transport.open()
        for read in reads { _ = try await read.value }
        #expect(transport.sentPaths.count == 3)
    }

    @Test func aPauseStoredByAnotherProcessStopsSending() async {
        let transport = HeldTransport(answer: .json("{}"))
        transport.open()
        let gate = SendGate(storedPause: { .ipBanned })
        let client = ManagementClient(baseURL: testBaseURL, managementKey: "test-key", transport: transport).sending(under: gate.ticket())

        await #expect(throws: APIError.pausedBeforeSending(.ipBanned)) { try await client.upstreamKeyCounters() }
        #expect(transport.sentPaths.isEmpty)
    }

    @Test func onlyATicketTakenAfterAManualActionPassesAfterAFailure() async throws {
        let transport = HeldTransport(answer: .json("{}"))
        transport.open()
        let gate = SendGate()
        let before = ManagementClient(baseURL: testBaseURL, managementKey: "test-key", transport: transport).sending(under: gate.ticket())
        gate.recordFailure(.keyRejected)
        gate.setPause(nil)
        let after = ManagementClient(baseURL: testBaseURL, managementKey: "test-key", transport: transport).sending(under: gate.ticket())

        await #expect(throws: APIError.pausedBeforeSending(.keyRejected)) { try await before.upstreamKeyCounters() }
        _ = try await after.upstreamKeyCounters()
        #expect(transport.sentPaths.count == 1)
    }
}

@Suite("Provider limit refresh: one request per server and shared work")
struct SharedProviderWorkTests {
    @Test func oneManagementRequestIsInFlightPerServerAcrossProviders() async {
        let stub = UpstreamStub(delay: .milliseconds(20))
        let targets = [target("claude", "c1"), target("codex", "x1", accountID: "acct"), target("kimi", "k1"), target("devin", "d1")]

        let results = await run(coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart)), targets, through: stub)

        #expect(results.allSatisfy { if case .refreshed = $0.outcome { true } else { false } })
        #expect(stub.peakConcurrencyInTotal == 1)
    }

    @Test func workSharedByTwoProfilesOfOneProxyIsSavedForTheLiveOne() async throws {
        let store = MemoryActiveRefreshStore()
        let deleted = ActiveRefreshServer(serverID: UUID(), baseURL: testBaseURL, generation: 0)
        let live = ActiveRefreshServer(serverID: UUID(), baseURL: URL(string: "HTTP://192.168.1.20:8317/")!, generation: 0)
        store.forgetServer(deleted.serverID)
        let stub = UpstreamStub(delay: .milliseconds(60))
        let client = ManagementClient(baseURL: testBaseURL, managementKey: "test-key", transport: stub)
        let refresher = coordinator(store, clock: TestClock(activeStart))

        async let first = refresher.refresh([target("devin", "d1")], server: deleted, mode: .manual) { try await client.apiCall($0, hooks: $1) }
        try await Task.sleep(for: .milliseconds(15))
        async let second = refresher.refresh([target("devin", "d1")], server: live, mode: .manual) { try await client.apiCall($0, hooks: $1) }
        let (deletedResults, liveResults) = await (first, second)

        #expect(stub.upstreamCount == 1)
        #expect(deletedResults.first?.outcome.quota != nil)
        #expect(liveResults.first?.outcome.quota != nil)
        #expect(store.activeQuotas(proxy: live.proxy)["d1"]?.windows.isEmpty == false)
    }

    @Test func aWaitIsSkippedOnceWhenThereIsNoReadingAndNoRecentRequest() {
        let now = activeStart
        var state = ActiveRefreshState()
        state.lastAttemptAt = now.addingTimeInterval(-ActiveRefreshPolicy.manualMinimum - 10)
        state.nextAllowedAt = now.addingTimeInterval(30)
        let account = target("claude", "c1")

        #expect(ActiveRefreshPolicy.decide(account, state: state, mode: .manual, hasReading: false, now: now) == .run(.manual))
        #expect(ActiveRefreshPolicy.decide(account, state: state, mode: .manual, hasReading: true, now: now) == .wait(until: now.addingTimeInterval(30), because: .recentlyChecked))

        var recent = state
        recent.lastAttemptAt = now.addingTimeInterval(-60)
        #expect(ActiveRefreshPolicy.decide(account, state: recent, mode: .manual, hasReading: false, now: now) == .wait(until: now.addingTimeInterval(30), because: .recentlyChecked))

        var rateLimited = state
        rateLimited.rateLimitedUntil = now.addingTimeInterval(30)
        #expect(ActiveRefreshPolicy.decide(account, state: rateLimited, mode: .manual, hasReading: false, now: now) == .wait(until: now.addingTimeInterval(30), because: .rateLimited))
    }

    @Test func waitsNeverExceedSevenDays() {
        let now = activeStart
        #expect(RetryAfter.date("1000000000000000", now: now) == nil)
        #expect(RetryAfter.date("Fri, 01 Jan 2100 00:00:00 GMT", now: now) == nil)
        let tenDays = now.addingTimeInterval(10 * 86_400)
        #expect(ActiveRefreshPolicy.rateLimitWait(provider: "claude", consecutive: 1, retryAfter: tenDays, now: now) == ActiveRefreshPolicy.longestWait)

        var state = ActiveRefreshState()
        state.recordAttempt(now: now, jitter: ActiveRefreshPolicy.maximumJitter)
        state.recordRateLimit(provider: "claude", retryAfter: tenDays, now: now)
        #expect(state.rateLimitedUntil == now.addingTimeInterval(ActiveRefreshPolicy.longestWait))
    }
}

@Suite("Provider limit refresh: explicit rejections and scoped windows")
struct ProviderStatusTests {
    static func codexUsage(primaryUsed: Int, weeklyUsed: Int) -> UpstreamStub {
        UpstreamStub { url, method in
            url.path() == "/backend-api/wham/usage"
                ? .json(#"{"rate_limit":{"limit_reached":true,"allowed":false,"primary_window":{"used_percent":\#(primaryUsed),"limit_window_seconds":18000,"reset_after_seconds":60},"secondary_window":{"used_percent":\#(weeklyUsed),"limit_window_seconds":604800,"reset_after_seconds":86400}}}"#)
                : UpstreamStub.healthy(url, method)
        }
    }

    @Test func aCodexLimitHitZeroesOnlyTheFullWindow() async throws {
        let results = await run(coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart)), [target("codex", "x1")], through: Self.codexUsage(primaryUsed: 100, weeklyUsed: 20))

        let quota = try #require(results.first?.outcome.quota)
        let session = try #require(quota.windows.first { $0.id == "session_5h" })
        let weekly = try #require(quota.windows.first { $0.id == "weekly_all" })
        #expect(session.remainingPercent(at: activeStart) == 0)
        #expect(weekly.status != QuotaBar.rejectedStatus)
        #expect(weekly.remainingPercent(at: activeStart) == 80)
        #expect(weekly.remainingPercent(at: activeStart.addingTimeInterval(120)) == 80)
        #expect(weekly.resetsAt == activeStart.addingTimeInterval(86_400))
        #expect(quota.note == nil)
    }

    @Test func aCodexBlockWithoutAFullWindowMarksTheAccountAndKeepsTheWindows() async throws {
        let results = await run(coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart)), [target("codex", "x1")], through: Self.codexUsage(primaryUsed: 20, weeklyUsed: 30))

        let quota = try #require(results.first?.outcome.quota)
        #expect(quota.note == .limitReached)
        let session = try #require(quota.windows.first { $0.id == "session_5h" })
        #expect(session.remainingPercent(at: activeStart) == 80)
        #expect(session.resetsAt == activeStart.addingTimeInterval(60))
        #expect(quota.windows.first { $0.id == "weekly_all" }?.remainingPercent(at: activeStart) == 70)
    }

    @Test func aScopedModelWindowWithoutPercentIsKeptAsUnknown() async throws {
        let stub = UpstreamStub { url, method in
            url.path() == "/api/oauth/usage" && url.query() == nil
                ? .json(#"{"five_hour":{"utilization":10,"resets_at":"2099-01-01T00:00:00Z"},"limits":[{"kind":"weekly_scoped","percent":null,"resets_at":"2099-01-03T00:00:00Z","scope":{"model":{"display_name":"Fable"}}}]}"#)
                : UpstreamStub.healthy(url, method)
        }
        let results = await run(coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart)), [target("claude", "c1")], through: stub)

        let model = try #require(results.first?.outcome.quota?.windows.first { $0.id == "weekly_fable" })
        #expect(model.usedPercent == nil)
        #expect(model.remainingPercent(at: activeStart) == nil)
        #expect(model.remainingPercent(at: date("2099-01-04T00:00:00Z")) == 100)
    }

    @Test func resetCountsShowOnlyForAccountsThatHadResets() {
        #expect(!ManualResets(remaining: 0).everHadResets)
        #expect(!ManualResets(remaining: 0, total: 0).everHadResets)
        #expect(ManualResets(remaining: 0, total: 3).everHadResets)
        #expect(ManualResets(remaining: 1).everHadResets)
    }
}
