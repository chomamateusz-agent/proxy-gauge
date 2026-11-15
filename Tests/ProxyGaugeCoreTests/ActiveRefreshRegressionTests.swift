import Foundation
import Synchronization
import Testing
@testable import ProxyGaugeCore

final class ScriptedManagement: HTTPTransport, @unchecked Sendable {
    typealias Answer = @Sendable (_ index: Int, _ url: URL) -> HTTPResponse

    private let lock = NSLock()
    private var sent: [URL] = []
    private let clock: TestClock?
    private let secondsPerRequest: TimeInterval
    private let answer: Answer

    init(clock: TestClock? = nil, secondsPerRequest: TimeInterval = 0, answer: @escaping Answer) {
        self.clock = clock
        self.secondsPerRequest = secondsPerRequest
        self.answer = answer
    }

    var count: Int { lock.withLock { sent.count } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let envelope = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any] ?? [:]
        let url = URL(string: envelope["url"] as? String ?? "")!
        let index = lock.withLock {
            sent.append(url)
            return sent.count - 1
        }
        clock?.advance(by: secondsPerRequest)
        return answer(index, url)
    }

    static func upstream(_ status: Int, _ body: String, headers: [String: [String]] = [:]) -> HTTPResponse {
        let payload: [String: Any] = ["status_code": status, "header": headers, "body": body]
        return HTTPResponse(statusCode: 200, body: try! JSONSerialization.data(withJSONObject: payload))
    }

    static let managementRejection = HTTPResponse(statusCode: 401, body: Data(#"{"error":"invalid management key"}"#.utf8))
    static let devinStatus = upstream(200, #"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":80}}}"#)
}

func run(_ coordinator: ActiveRefreshCoordinator, _ targets: [ActiveTarget], mode: ActiveRefreshMode = .manual, server: ActiveRefreshServer = activeServer, through transport: any HTTPTransport, mayContactServer: @escaping ActiveRefreshCoordinator.Admission = { true }, onRejection: @escaping ActiveRefreshCoordinator.RejectionHandler = { _ in }) async -> [ActiveRefreshResult] {
    let client = ManagementClient(baseURL: testBaseURL, managementKey: "test-key", transport: transport)
    return await coordinator.refresh(targets, server: server, mode: mode, mayContactServer: mayContactServer, onManagementRejection: onRejection) {
        try await client.apiCall($0, hooks: $1)
    }
}

@Suite("Provider limit refresh: interleavings")
struct ActiveRefreshInterleavingTests {
    @Test func aManagementRejectionStopsRequestsQueuedForTheSameProvider() async {
        let transport = ScriptedManagement { index, _ in index == 1 ? ScriptedManagement.managementRejection : ScriptedManagement.devinStatus }
        let rejections = Mutex(0)
        let results = await run(
            coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart)),
            [target("devin", "d1"), target("devin", "d2"), target("devin", "d3")],
            through: transport,
            onRejection: { _ in rejections.withLock { $0 += 1 } }
        )
        #expect(transport.count == 2)
        #expect(rejections.withLock { $0 } == 1)
        #expect(results.map(\.outcome).filter { $0 == .notSent }.count == 1)
    }

    @Test func theRejectionIsRecordedBeforeTheProviderLaneIsReleased() async {
        let latch = Mutex(false)
        let transport = ScriptedManagement { index, _ in index == 0 ? ScriptedManagement.managementRejection : ScriptedManagement.devinStatus }
        let refresher = coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart))
        let mayContact: ActiveRefreshCoordinator.Admission = { !latch.withLock { $0 } }
        let onRejection: ActiveRefreshCoordinator.RejectionHandler = { _ in latch.withLock { $0 = true } }
        async let window = run(refresher, [target("devin", "d1"), target("devin", "d2")], through: transport, mayContactServer: mayContact, onRejection: onRejection)
        async let menuBar = run(refresher, [target("devin", "d3"), target("devin", "d4")], through: transport, mayContactServer: mayContact, onRejection: onRejection)
        let outcomes = await (window + menuBar).map(\.outcome)
        #expect(transport.count == 1)
        #expect(outcomes.filter { $0 == .notSent }.count == 3)
    }

    @Test func revokingPermissionMidBatchStopsFurtherSends() async {
        let allowed = Mutex(true)
        let transport = ScriptedManagement { _, _ in
            allowed.withLock { $0 = false }
            return ScriptedManagement.devinStatus
        }
        let results = await run(
            coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart)),
            [target("devin", "d1"), target("devin", "d2"), target("devin", "d3")],
            mode: .automatic(interval: 15 * 60, origin: .visibleApp),
            through: transport,
            mayContactServer: { allowed.withLock { $0 } }
        )
        #expect(transport.count == 1)
        #expect(results.map(\.outcome).filter { $0 == .notSent }.count == 2)
    }

    @Test func unsentAccountsKeepTheirAllowance() async {
        let store = MemoryActiveRefreshStore()
        let transport = ScriptedManagement { _, _ in ScriptedManagement.devinStatus }
        _ = await run(coordinator(store, clock: TestClock(activeStart)), [target("devin", "d1")], through: transport, mayContactServer: { false })
        #expect(transport.count == 0)
        #expect(store.activeRefreshStates(proxy: activeServer.proxy)["d1"] == nil)
    }

    @Test func minimumWaitsCountFromTheActualSend() async throws {
        let clock = TestClock(activeStart)
        let store = MemoryActiveRefreshStore()
        let transport = ScriptedManagement(clock: clock, secondsPerRequest: 10 * 60) { _, _ in ScriptedManagement.devinStatus }
        _ = await run(coordinator(store, clock: clock), [target("devin", "d1"), target("devin", "d2")], through: transport)
        let states = store.activeRefreshStates(proxy: activeServer.proxy)
        let first = try #require(states["d1"])
        let second = try #require(states["d2"])
        #expect(first.lastAttemptAt == activeStart)
        #expect(second.lastAttemptAt == activeStart.addingTimeInterval(10 * 60))
        #expect(second.nextAllowedAt == activeStart.addingTimeInterval(20 * 60 + ActiveRefreshPolicy.manualMinimum))
    }

    @Test func retryAfterAndRelativeResetsCountFromTheResponse() async throws {
        let clock = TestClock(activeStart)
        let store = MemoryActiveRefreshStore()
        let limited = ScriptedManagement(clock: clock, secondsPerRequest: 10 * 60) { _, _ in
            ScriptedManagement.upstream(429, #"{"error":"slow down"}"#, headers: ["Retry-After": ["3600"]])
        }
        _ = await run(coordinator(store, clock: clock), [target("codex", "x1")], through: limited)
        let state = try #require(store.activeRefreshStates(proxy: activeServer.proxy)["x1"])
        let responseTime = activeStart.addingTimeInterval(10 * 60)
        #expect(state.rateLimitedUntil == responseTime.addingTimeInterval(3_600))
        #expect(state.lastAttemptAt == activeStart)

        let resetClock = TestClock(activeStart)
        let usage = ScriptedManagement(clock: resetClock, secondsPerRequest: 90) { _, _ in
            ScriptedManagement.upstream(200, #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_after_seconds":60}}}"#)
        }
        let results = await run(coordinator(MemoryActiveRefreshStore(), clock: resetClock), [target("codex", "x2")], through: usage)
        let window = try #require(results.first?.outcome.quota?.windows.first)
        #expect(window.sampledAt == activeStart.addingTimeInterval(90))
        #expect(window.resetsAt == activeStart.addingTimeInterval(150))
        #expect(!window.hasReset(at: activeStart.addingTimeInterval(90)))
    }

    @Test func aResultForADeletedOrChangedServerIsNotWritten() async {
        let store = MemoryActiveRefreshStore()
        let transport = ScriptedManagement { _, _ in
            store.forgetServer(activeServerID)
            return ScriptedManagement.devinStatus
        }
        let results = await run(coordinator(store, clock: TestClock(activeStart)), [target("devin", "d1")], through: transport)
        #expect(results.first?.outcome.quota != nil)
        #expect(store.activeQuotas(proxy: activeServer.proxy).isEmpty)
        #expect(store.activeRefreshStates(proxy: activeServer.proxy)["d1"]?.lastSuccessAt != nil)
    }

    @Test func readingsAlreadyReceivedSurviveAStoppedRun() async throws {
        let store = MemoryActiveRefreshStore()
        let allowed = Mutex(true)
        let stub = UpstreamStub { url, method in
            allowed.withLock { $0 = false }
            return UpstreamStub.healthy(url, method)
        }
        let results = await run(coordinator(store, clock: TestClock(activeStart)), [target("claude", "c1")], through: stub, mayContactServer: { allowed.withLock { $0 } })
        #expect(stub.upstreamCount == 1)
        guard case .stopped(let partial?) = results.first?.outcome else {
            Issue.record("expected a stopped run with readings, got \(String(describing: results.first?.outcome))")
            return
        }
        #expect(partial.windows.map(\.id) == ["session_5h", "weekly_all"])
        #expect(store.activeQuotas(proxy: activeServer.proxy)["c1"]?.windows.count == 2)
    }

    @Test func aFailedProfileIsNotRecordedAsChecked() async throws {
        let store = MemoryActiveRefreshStore()
        let stub = UpstreamStub { url, method in
            url.path() == "/api/oauth/profile" ? .status(500) : UpstreamStub.healthy(url, method)
        }
        _ = await run(coordinator(store, clock: TestClock(activeStart)), [target("claude", "c1")], through: stub)
        let state = try #require(store.activeRefreshStates(proxy: activeServer.proxy)["c1"])
        #expect(state.lastSuccessAt != nil)
        #expect(state.profileCheckedAt == nil)
    }
}

@Suite("Provider limit refresh: parsing")
struct ActiveQuotaParsingTests {
    func refresh(_ target: ActiveTarget, store: MemoryActiveRefreshStore = MemoryActiveRefreshStore(), clock: TestClock = TestClock(activeStart), _ answer: @escaping @Sendable (URL) -> UpstreamAnswer?) async -> (ActiveRefreshOutcome?, UpstreamStub) {
        let stub = UpstreamStub { url, method in answer(url) ?? UpstreamStub.healthy(url, method) }
        let results = await run(coordinator(store, clock: clock), [target], through: stub)
        return (results.first?.outcome, stub)
    }

    @Test(arguments: [
        #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":"1e30"}}}"#,
        #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":1e300}}}"#,
        #"{"plan_type":"plus","rate_limit_reset_credits":{"available_count":1e40}}"#
    ])
    func hugeCodexNumbersAreUnreadable(body: String) async {
        let (outcome, _) = await refresh(target("codex", "x1")) { url in url.path() == "/backend-api/wham/usage" ? .json(body) : nil }
        #expect(outcome == .failed(.unreadable))
    }

    @Test func hugeKimiDurationsAreUnreadable() async {
        let (outcome, _) = await refresh(target("kimi", "k1")) { url in
            url.path() == "/coding/v1/usages" ? .json(#"{"limits":[{"window":{"duration":1e30,"timeUnit":"TIME_UNIT_WEEK"},"detail":{"used":1,"limit":2}}]}"#) : nil
        }
        #expect(outcome == .failed(.unreadable))
    }

    @Test func hugeClaudeGrantCountsAreDropped() async {
        let (outcome, _) = await refresh(target("claude", "c1")) { url in
            url.query()?.contains("cedar_ember") == true ? .json(#"{"cedar_ember":{"eligible":true,"grants":[{"resets_left":1e300,"resets_total":1e300}]}}"#) : nil
        }
        #expect(outcome?.quota?.windows.isEmpty == false)
        #expect(outcome?.quota?.resets == nil)
    }

    @Test func reportedWindowsWithoutUtilizationAreKept() async throws {
        let (claude, _) = await refresh(target("claude", "c1")) { url in
            url.path() == "/api/oauth/usage" && url.query() == nil
                ? .json(#"{"five_hour":{"utilization":null,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2099-01-05T00:00:00Z"}}"#)
                : nil
        }
        let session = try #require(claude?.quota?.windows.first { $0.id == "session_5h" })
        #expect(session.usedPercent == nil)
        #expect(session.remainingPercent(at: activeStart) == nil)
        #expect(session.remainingPercent(at: date("2099-01-02T00:00:00Z")) == 100)

        let (codex, _) = await refresh(target("codex", "x1")) { url in
            url.path() == "/backend-api/wham/usage" ? .json(#"{"rate_limit":{"limit_reached":true,"primary_window":{"limit_window_seconds":18000}}}"#) : nil
        }
        let unknown = try #require(codex?.quota?.windows.first)
        #expect(unknown.usedPercent == nil)
        #expect(unknown.remainingPercent(at: activeStart) == nil)
        #expect(codex?.quota?.note == .limitReached)
    }

    @Test func freshReadingsClearCreditsAndResetsTheProviderEmptied() async throws {
        let store = MemoryActiveRefreshStore()
        let clock = TestClock(activeStart)
        _ = await refresh(target("codex", "x1"), store: store, clock: clock) { _ in nil }
        #expect(store.activeQuotas(proxy: activeServer.proxy)["x1"]?.credits == ProviderCredits(balance: 3.5))
        #expect(store.activeQuotas(proxy: activeServer.proxy)["x1"]?.resets?.remaining == 2)

        clock.advance(by: 10 * 60)
        _ = await refresh(target("codex", "x1"), store: store, clock: clock) { url in
            switch url.path() {
            case "/backend-api/wham/usage": .json(#"{"plan_type":"plus","credits":{"has_credits":false},"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000}}}"#)
            case "/backend-api/wham/rate-limit-reset-credits": .json(#"{"credits":[]}"#)
            default: nil
            }
        }
        let cleared = try #require(store.activeQuotas(proxy: activeServer.proxy)["x1"])
        #expect(cleared.credits == nil)
        #expect(cleared.resets?.remaining == 0)
        #expect(cleared.planActiveUntil == nil)

        clock.advance(by: 10 * 60)
        _ = await refresh(target("codex", "x1"), store: store, clock: clock) { url in
            switch url.path() {
            case "/backend-api/wham/usage": .json(#"{"plan_type":"plus","credits":null,"rate_limit":{"primary_window":{"used_percent":30,"limit_window_seconds":18000}}}"#)
            case "/backend-api/wham/rate-limit-reset-credits": .status(500)
            default: nil
            }
        }
        let kept = try #require(store.activeQuotas(proxy: activeServer.proxy)["x1"])
        #expect(kept.credits == nil)
        #expect(kept.resets?.remaining == 0)
        #expect(kept.windows.first?.usedPercent == 30)
    }

    @Test func absentFieldsKeepTheLastReading() {
        let first = ActiveQuota(credentialID: "c", provider: "codex", observedAt: .distantPast, credits: ProviderCredits(balance: 3), resets: ManualResets(remaining: 1))
        let later = ActiveQuota(credentialID: "c", provider: "codex", observedAt: .now)
        #expect(later.superseding(first, read: []).credits == ProviderCredits(balance: 3))
        #expect(later.superseding(first, read: [.credits]).credits == nil)
        #expect(later.superseding(first, read: [.resets]).resets == nil)
    }

    @Test func xaiBillingErrorsNeverRunThePaidCompletion() async {
        let (outcome, stub) = await refresh(target("xai", "g1")) { url in
            url.path() == "/v1/billing" ? .status(500) : nil
        }
        #expect(!stub.upstreamURLs.contains(XAIAdapter.completionURL))
        #expect(outcome == .failed(.upstream(status: 500)))

        let (mixed, mixedStub) = await refresh(target("xai", "g2")) { url in
            guard url.path() == "/v1/billing" else { return nil }
            return url.query()?.contains("credits") == true ? .json("{}") : .json("not json")
        }
        #expect(!mixedStub.upstreamURLs.contains(XAIAdapter.completionURL))
        #expect(mixed == .failed(.unreadable))
    }

    @Test func xaiKeepsTheFirstBillingReadingWhenTheSecondIsRefused() async throws {
        let store = MemoryActiveRefreshStore()
        let (outcome, _) = await refresh(target("xai", "g1"), store: store) { url in
            url.path() == "/v1/billing" && url.query() == nil ? .status(429) : nil
        }
        guard case .rateLimited(_, let partial?) = outcome else {
            Issue.record("expected a rate limit with partial data, got \(String(describing: outcome))")
            return
        }
        #expect(partial.windows.first?.usedPercent == 37)
        #expect(store.activeQuotas(proxy: activeServer.proxy)["g1"]?.credits == ProviderCredits(balance: 25, currency: "USD"))
    }
}

@Suite("Provider limit refresh: identity")
struct ActiveRefreshIdentityTests {
    @Test func proxyKeysIgnoreCaseDefaultPortsAndTrailingSlashes() {
        let key = ActiveRefreshServer.proxyKey(URL(string: "http://proxy.example.com/cpa")!)
        #expect(ActiveRefreshServer.proxyKey(URL(string: "HTTP://Proxy.Example.com:80/cpa/")!) == key)
        #expect(ActiveRefreshServer.proxyKey(URL(string: "http://proxy.example.com:8317/cpa")!) != key)
        #expect(ActiveRefreshServer.proxyKey(URL(string: "https://proxy.example.com/cpa")!) != key)
    }

    @Test func targetsUseTheAuthFileRatherThanTheAuthIndex() {
        var credential = Credential(name: "claude-a.json", authIndex: "7f", provider: "claude")
        #expect(ActiveTarget(credential: credential, now: .now).credentialID == "claude-a.json")
        credential.credentialID = "file-id"
        #expect(ActiveTarget(credential: credential, now: .now).credentialID == "file-id")
        #expect(ActiveTarget(credential: credential, now: .now).authIndex == "7f")
    }
}

@Suite("Elapsed time")
struct ElapsedTimeTests {
    @Test func zeroSecondsAreDropped() {
        let start = activeStart
        let english = Locale(identifier: "en_US")
        #expect(ElapsedTime.text(from: start, to: start.addingTimeInterval(42 * 60), locale: english) == "42 min")
        #expect(ElapsedTime.text(from: start, to: start.addingTimeInterval(42 * 60 + 7), locale: english) == "42 min")
        #expect(ElapsedTime.text(from: start, to: start.addingTimeInterval(2 * 3_600), locale: english) == "2 hr")
        #expect(ElapsedTime.text(from: start, to: start.addingTimeInterval(20), locale: english) == "20 sec")
    }
}
