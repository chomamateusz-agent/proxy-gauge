import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Provider limit refresh: requests")
struct ActiveRefreshRequestTests {
    @Test func manualRefreshSendsThePanelRequestsPerProvider() async {
        let expectations: [(ActiveTarget, String, Int)] = [
            (target("claude", "c1"), "api.anthropic.com", 3),
            (target("codex", "x1", accountID: "acct-1"), "chatgpt.com", 3),
            (target("codex", "x2"), "chatgpt.com", 2),
            (target("antigravity", "a1", projectID: "demo-project"), "daily-cloudcode-pa.googleapis.com", 2),
            (target("kimi", "k1"), "api.kimi.com", 2),
            (target("devin", "d1"), "server.codeium.com", 1),
            (target("xai", "g1"), "cli-chat-proxy.grok.com", 4)
        ]
        for (target, host, expected) in expectations {
            let stub = UpstreamStub()
            let results = await run(coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart)), [target], through: stub)
            #expect(stub.count(host: host) == expected, "\(target.provider) \(target.credentialID)")
            #expect(stub.upstreamCount == expected)
            #expect(results.first?.outcome.quota != nil)
        }
    }

    @Test func requestsMirrorThePanelShape() async throws {
        let stub = UpstreamStub()
        _ = await run(coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart)), [target("claude", "c1")], through: stub)
        #expect(stub.upstreamURLs.map(\.absoluteString) == [
            "https://api.anthropic.com/api/oauth/usage",
            "https://api.anthropic.com/api/oauth/profile",
            "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1"
        ])
        let usageHeaders = try #require(stub.recordedHeaders.first)
        #expect(usageHeaders["Authorization"] == "Bearer $TOKEN$")
        #expect(usageHeaders["anthropic-beta"] == "oauth-2025-04-20")
        #expect(usageHeaders["Accept"] == "application/json")
        #expect(stub.recordedAuthIndexes == ["c1", "c1", "c1"])

        let devin = UpstreamStub()
        _ = await run(coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart)), [target("devin", "d1")], through: devin)
        #expect(devin.recordedBodies.first??.contains(#""apiKey":"$TOKEN$""#) == true)
    }

    @Test func xaiFallsBackToThePaidKeyCheckOnlyWhenBillingIsEmpty() async {
        let stub = UpstreamStub { url, method in
            url.host() == "cli-chat-proxy.grok.com" && url.path() == "/v1/billing" ? .json("{}") : UpstreamStub.healthy(url, method)
        }
        let results = await run(coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart)), [target("xai", "g1")], through: stub)
        #expect(stub.upstreamCount == 6)
        #expect(stub.upstreamURLs.contains(XAIAdapter.completionURL))
        #expect(results.first?.outcome.quota?.note == .paidKeyAnswered)
    }

    @Test func automaticRefreshSkipsGrantsAndRefreshesTheProfileDaily() async {
        let clock = TestClock(activeStart)
        let store = MemoryActiveRefreshStore()
        let stub = UpstreamStub()
        let refresher = coordinator(store, clock: clock)
        let automatic = ActiveRefreshMode.automatic(interval: 30 * 60, origin: .visibleApp)

        _ = await run(refresher, [target("claude", "c1")], mode: automatic, through: stub)
        #expect(stub.upstreamURLs.map(\.path) == ["/api/oauth/usage", "/api/oauth/profile"])

        clock.advance(by: 31 * 60)
        _ = await run(refresher, [target("claude", "c1")], mode: automatic, through: stub)
        #expect(stub.upstreamCount == 3)
        #expect(stub.upstreamURLs.last?.path == "/api/oauth/usage")

        clock.advance(by: 24 * 3_600)
        _ = await run(refresher, [target("claude", "c1")], mode: automatic, through: stub)
        #expect(stub.upstreamURLs.suffix(2).map(\.path) == ["/api/oauth/usage", "/api/oauth/profile"])
        #expect(!stub.upstreamURLs.contains { $0.query()?.contains("cedar_ember") == true })
    }

    @Test func claudeIsNeverRefreshedAutomaticallyMoreOftenThanEveryThirtyMinutes() async {
        let clock = TestClock(activeStart)
        let stub = UpstreamStub()
        let refresher = coordinator(MemoryActiveRefreshStore(), clock: clock)
        let fifteen = ActiveRefreshMode.automatic(interval: 15 * 60, origin: .visibleApp)

        _ = await run(refresher, [target("claude", "c1"), target("codex", "x1")], mode: fifteen, through: stub)
        let first = (claude: stub.count(host: "api.anthropic.com"), codex: stub.count(host: "chatgpt.com"))
        clock.advance(by: 16 * 60)
        let results = await run(refresher, [target("claude", "c1"), target("codex", "x1")], mode: fifteen, through: stub)

        #expect(stub.count(host: "api.anthropic.com") == first.claude)
        #expect(stub.count(host: "chatgpt.com") > first.codex)
        guard case .waiting(let until, .recentlyChecked) = results[0].outcome else {
            Issue.record("Claude should wait, got \(results[0].outcome)")
            return
        }
        #expect(until == clock.now.addingTimeInterval(14 * 60))
    }

    @Test func automaticNeverRunsFromTheWidgetMenuBarOrBackground() async {
        let stub = UpstreamStub()
        let refresher = coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart))
        for origin in [ActiveRefreshOrigin.widget, .menuBar, .background] {
            let results = await run(refresher, [target("codex", "x1")], mode: .automatic(interval: 30 * 60, origin: origin), through: stub)
            #expect(results.first?.outcome == .skipped(.notVisible))
        }
        #expect(stub.upstreamCount == 0)
    }

    @Test func xaiAndGoogleAreExcludedFromAutomaticRefresh() async {
        let stub = UpstreamStub()
        let refresher = coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart))
        let results = await run(refresher, [target("xai", "g1"), target("antigravity", "a1", projectID: "p")], mode: .automatic(interval: 60 * 60, origin: .visibleApp), through: stub)
        #expect(results.map(\.outcome) == [.skipped(.excludedFromAutomatic), .skipped(.excludedFromAutomatic)])
        #expect(stub.upstreamCount == 0)
    }

    @Test func unsupportedAndDisabledAccountsAreNotContacted() async {
        let stub = UpstreamStub()
        let results = await run(coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart)), [target("gemini-cli", "gc"), target("claude", "c9", disabled: true), target("antigravity", "a2")], through: stub)
        #expect(results.map(\.outcome) == [.skipped(.unsupported), .skipped(.disabled), .skipped(.missingProject)])
        #expect(stub.upstreamCount == 0)
    }
}

@Suite("Provider limit refresh: concurrency")
struct ActiveRefreshConcurrencyTests {
    @Test func oneInFlightRefreshPerCredential() async {
        let stub = UpstreamStub(delay: .milliseconds(40))
        let refresher = coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart))
        async let first = run(refresher, [target("codex", "x1")], through: stub)
        async let second = run(refresher, [target("codex", "x1")], through: stub)
        async let third = run(refresher, [target("codex", "x1")], through: stub)
        let outcomes = await [first, second, third].flatMap { $0 }.map(\.outcome)
        #expect(stub.count(host: "chatgpt.com") == 2)
        #expect(outcomes.filter { if case .refreshed = $0 { true } else { false } }.count >= 1)
        #expect(outcomes.allSatisfy { outcome in
            switch outcome {
            case .refreshed, .waiting(_, .recentlyChecked): true
            default: false
            }
        })
    }

    @Test func atMostOneActiveRequestPerProvider() async {
        let stub = UpstreamStub(delay: .milliseconds(20))
        let refresher = coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart))
        let claude = (1...4).map { target("claude", "c\($0)") }
        let codex = (1...3).map { target("codex", "x\($0)", accountID: "acct-\($0)") }
        async let batch = run(refresher, claude + codex, through: stub)
        async let menuBar = run(refresher, [target("claude", "c5")], through: stub)
        _ = await (batch, menuBar)
        #expect(stub.count(host: "api.anthropic.com") == 15)
        #expect(stub.count(host: "chatgpt.com") == 9)
        #expect(stub.peakConcurrency(host: "api.anthropic.com") == 1)
        #expect(stub.peakConcurrency(host: "chatgpt.com") == 1)
    }
}

@Suite("Provider limit refresh: throttling")
struct ActiveRefreshThrottlingTests {
    let now = Date(timeIntervalSince1970: 1_794_700_000)

    @Test(arguments: [
        ("7200", 7_200.0),
        ("0", 30 * 60.0),
        ("-5", 30 * 60.0),
        ("soon", 30 * 60.0),
        (nil, 30 * 60.0),
        ("36000", 36_000.0)
    ] as [(String?, TimeInterval)])
    func retryAfterSecondsAreHonouredAboveThePolicyFloor(header: String?, expected: TimeInterval) {
        let retryAfter = RetryAfter.date(header, now: now)
        #expect(ActiveRefreshPolicy.rateLimitWait(provider: "claude", consecutive: 1, retryAfter: retryAfter, now: now) == expected)
    }

    @Test func retryAfterHTTPDatesAreParsedAndPastDatesIgnored() {
        #expect(RetryAfter.date("Sun, 15 Nov 2026 12:00:00 GMT", now: Date(timeIntervalSince1970: 1_794_700_000)) == Date(timeIntervalSince1970: 1_794_744_000))
        #expect(RetryAfter.date("Sun, 15 Nov 2026 12:00:00 GMT", now: Date(timeIntervalSince1970: 1_794_800_000)) == nil)
    }

    @Test func backoffDoublesToTheSixHourCap() {
        let claude = (1...6).map { ActiveRefreshPolicy.rateLimitWait(provider: "claude", consecutive: $0, retryAfter: nil, now: now) / 60 }
        let codex = (1...7).map { ActiveRefreshPolicy.rateLimitWait(provider: "codex", consecutive: $0, retryAfter: nil, now: now) / 60 }
        #expect(claude == [30, 60, 120, 240, 360, 360])
        #expect(codex == [15, 30, 60, 120, 240, 360, 360])
    }

    @Test func nestedRateLimitKeepsLastGoodDataAndHonoursRetryAfter() async throws {
        let clock = TestClock(activeStart)
        let store = MemoryActiveRefreshStore()
        let refresher = coordinator(store, clock: clock, jitter: 0.1)
        _ = await run(refresher, [target("codex", "x1")], through: UpstreamStub())
        let lastGood = try #require(store.activeQuotas(proxy: activeServer.proxy)["x1"])

        clock.advance(by: 10 * 60)
        let limited = UpstreamStub { _, _ in .status(429, headers: ["Retry-After": ["3600"]]) }
        let results = await run(refresher, [target("codex", "x1")], through: limited)

        #expect(limited.upstreamCount == 1)
        #expect(results.first?.outcome == .rateLimited(until: clock.now.addingTimeInterval(3_600 * 1.1), partial: nil))
        #expect(store.activeQuotas(proxy: activeServer.proxy)["x1"] == lastGood)
        let state = try #require(store.activeRefreshStates(proxy: activeServer.proxy)["x1"])
        #expect(state.isRateLimited(at: clock.now.addingTimeInterval(3_600)))
        #expect(!state.isRateLimited(at: clock.now.addingTimeInterval(3_600 * 1.1 + 1)))
    }

    @Test func jitterIsAddedAfterTheMinimum() async throws {
        let clock = TestClock(activeStart)
        let store = MemoryActiveRefreshStore()
        let limited = UpstreamStub { _, _ in .status(429) }
        _ = await run(coordinator(store, clock: clock, jitter: 0.2), [target("claude", "c1")], through: limited)
        let state = try #require(store.activeRefreshStates(proxy: activeServer.proxy)["c1"])
        #expect(state.nextAllowedAt == clock.now.addingTimeInterval(30 * 60 * 1.2))
    }

    @Test func backoffSurvivesANewCoordinatorAndBlocksManualRefresh() async {
        let clock = TestClock(activeStart)
        let store = MemoryActiveRefreshStore()
        _ = await run(coordinator(store, clock: clock), [target("claude", "c1")], through: UpstreamStub { _, _ in .status(429) })

        clock.advance(by: 20 * 60)
        let afterRelaunch = UpstreamStub()
        let results = await run(coordinator(store, clock: clock), [target("claude", "c1")], through: afterRelaunch)

        #expect(afterRelaunch.upstreamCount == 0)
        #expect(results.first?.outcome == .waiting(until: clock.now.addingTimeInterval(10 * 60), because: .rateLimited))

        clock.advance(by: 11 * 60)
        _ = await run(coordinator(store, clock: clock), [target("claude", "c1")], through: afterRelaunch)
        #expect(afterRelaunch.upstreamCount == 3)
    }

    @Test func repeatedRateLimitsSuspendAutomaticRefreshUntilAManualSuccess() async throws {
        let clock = TestClock(activeStart)
        let store = MemoryActiveRefreshStore()
        let refresher = coordinator(store, clock: clock)
        let limited = UpstreamStub { _, _ in .status(429) }
        let automatic = ActiveRefreshMode.automatic(interval: 15 * 60, origin: .visibleApp)
        for _ in 1...3 {
            _ = await run(refresher, [target("codex", "x1")], mode: automatic, through: limited)
            clock.advance(by: 7 * 3_600)
        }
        #expect(limited.upstreamCount == 3)
        #expect(store.activeRefreshStates(proxy: activeServer.proxy)["x1"]?.automaticSuspended == true)

        let healthy = UpstreamStub()
        let skipped = await run(refresher, [target("codex", "x1")], mode: automatic, through: healthy)
        #expect(skipped.first?.outcome == .skipped(.automaticSuspended))
        _ = await run(refresher, [target("codex", "x1")], through: healthy)
        #expect(store.activeRefreshStates(proxy: activeServer.proxy)["x1"]?.automaticSuspended == false)
    }

    @Test func providerRejectionStopsAutomaticRefreshUntilManualAction() async {
        let clock = TestClock(activeStart)
        let store = MemoryActiveRefreshStore()
        let refresher = coordinator(store, clock: clock)
        let rejected = UpstreamStub { _, _ in .status(403) }
        let first = await run(refresher, [target("kimi", "k1")], through: rejected)
        #expect(first.first?.outcome == .rejected(status: 403))

        clock.advance(by: 2 * 3_600)
        let healthy = UpstreamStub()
        let automatic = await run(refresher, [target("kimi", "k1")], mode: .automatic(interval: 15 * 60, origin: .visibleApp), through: healthy)
        #expect(automatic.first?.outcome == .skipped(.rejectedByProvider))
        #expect(healthy.upstreamCount == 0)

        let manual = await run(refresher, [target("kimi", "k1")], through: healthy)
        #expect(manual.first?.outcome.quota != nil)
        #expect(store.activeRefreshStates(proxy: activeServer.proxy)["k1"]?.rejectedStatus == nil)
    }

    @Test func optionalRequestRateLimitKeepsTheFreshUsage() async throws {
        let store = MemoryActiveRefreshStore()
        let stub = UpstreamStub { url, method in
            url.path() == "/api/oauth/profile" ? .status(429) : UpstreamStub.healthy(url, method)
        }
        let results = await run(coordinator(store, clock: TestClock(activeStart)), [target("claude", "c1")], through: stub)
        #expect(stub.upstreamCount == 2)
        guard case .rateLimited(_, let partial?) = results.first?.outcome else {
            Issue.record("expected a rate limit with partial data")
            return
        }
        #expect(partial.windows.map(\.id) == ["session_5h", "weekly_all"])
        #expect(store.activeQuotas(proxy: activeServer.proxy)["c1"]?.windows.count == 2)
    }

    @Test func manualRefreshWaitsForTheShortMinimumAfterASuccess() async {
        let clock = TestClock(activeStart)
        let stub = UpstreamStub()
        let refresher = coordinator(MemoryActiveRefreshStore(), clock: clock)
        _ = await run(refresher, [target("devin", "d1")], through: stub)
        clock.advance(by: 60)
        let again = await run(refresher, [target("devin", "d1")], through: stub)
        #expect(stub.upstreamCount == 1)
        #expect(again.first?.outcome == .waiting(until: clock.now.addingTimeInterval(4 * 60), because: .recentlyChecked))
    }

    @Test func managementRejectionStopsTheBatchAfterOneAttempt() async {
        let stub = UpstreamStub()
        stub.rejectManagementKey()
        let counting = CountingTransport(stub)
        let countingClient = ManagementClient(baseURL: testBaseURL, managementKey: "bad", transport: counting)
        let targets = [target("claude", "c1"), target("codex", "x1"), target("kimi", "k1"), target("devin", "d1")]
        let results = await coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart)).refresh(targets, server: activeServer, mode: .manual) {
            try await countingClient.apiCall($0, hooks: $1)
        }
        #expect(counting.count == 1)
        #expect(results.filter { if case .managementFailed = $0.outcome { true } else { false } }.count == 1)
        #expect(results.filter { $0.outcome == .notSent }.count == 3)
    }
}

final class CountingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    private let inner: any HTTPTransport

    init(_ inner: any HTTPTransport) {
        self.inner = inner
    }

    var count: Int { lock.withLock { sent } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { sent += 1 }
        return try await inner.send(request)
    }
}

@Suite("Provider limit refresh: results")
struct ActiveQuotaResultTests {
    @Test func adaptersNormaliseEachProvider() async throws {
        let store = MemoryActiveRefreshStore()
        let targets = [
            target("claude", "c1"),
            target("codex", "x1", accountID: "acct"),
            target("antigravity", "a1", projectID: "p"),
            target("kimi", "k1"),
            target("devin", "d1"),
            target("xai", "g1")
        ]
        let results = await run(coordinator(store, clock: TestClock(activeStart)), targets, through: UpstreamStub())
        let quotas = Dictionary(uniqueKeysWithValues: results.compactMap { result in result.outcome.quota.map { (result.credentialID, $0) } })

        let claude = try #require(quotas["c1"])
        #expect(claude.windows.map(\.id) == ["session_5h", "weekly_all"])
        #expect(claude.windows.allSatisfy { $0.source == .provider })
        #expect(claude.plan == "max 5x")
        #expect(claude.resets?.remaining == 2)
        #expect(claude.resets?.total == 3)
        #expect(claude.resets?.expiresAt == date("2026-11-20T10:00:00Z"))
        #expect(claude.extraUsage == ExtraUsage(isEnabled: true, used: 12.4, limit: 50, currency: "USD"))

        let codex = try #require(quotas["x1"])
        #expect(codex.windows.map(\.id) == ["session_5h", "weekly_all"])
        #expect(codex.plan == "plus")
        #expect(codex.credits == ProviderCredits(balance: 3.5))
        #expect(codex.resets?.remaining == 1)
        #expect(codex.resets?.expiresAt == date("2026-11-25T00:00:00Z"))
        #expect(codex.planActiveUntil == date("2026-12-01T00:00:00Z"))

        let antigravity = try #require(quotas["a1"])
        #expect(antigravity.windows.first?.usedPercent == 25)
        #expect(antigravity.windows.first?.label == "Gemini Pro · 5h")
        #expect(antigravity.plan == "pro")

        let kimi = try #require(quotas["k1"])
        #expect(Set(kimi.windows.map(\.id)) == ["session_5h", "weekly_all"])
        #expect(kimi.plan == "Andante")

        let devin = try #require(quotas["d1"])
        #expect(devin.windows.map(\.usedPercent) == [20, 35])
        #expect(devin.plan == "pro")

        let xai = try #require(quotas["g1"])
        #expect(xai.windows.first?.id == "weekly_all")
        #expect(xai.windows.first?.usedPercent == 37)
        #expect(xai.credits == ProviderCredits(balance: 25, currency: "USD"))
        #expect(xai.plan == "SuperGrok")
    }

    @Test func claudeIdleWindowStartsOnUse() async throws {
        let stub = UpstreamStub { url, method in
            url.path() == "/api/oauth/usage" && url.query() == nil
                ? .json(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":10,"resets_at":"2026-11-19T10:00:00Z"}}"#)
                : UpstreamStub.healthy(url, method)
        }
        let results = await run(coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart)), [target("claude", "c1")], through: stub)
        let session = try #require(results.first?.outcome.quota?.windows.first { $0.id == "session_5h" })
        #expect(session.startsOnUse(provider: "claude", at: .now))
    }

    @Test func mergeKeepsTheNewestObservationPerWindow() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let passive = [
            QuotaBar(id: "session_5h", usedPercent: 10, sampledAt: new, source: .proxy),
            QuotaBar(id: "weekly_all", usedPercent: 50, sampledAt: old, source: .proxy),
            QuotaBar(id: "weekly_fable", usedPercent: 5, sampledAt: old, source: .proxy)
        ]
        let active = ActiveQuota(credentialID: "c", provider: "claude", observedAt: Date(timeIntervalSince1970: 1_500), windows: [
            QuotaBar(id: "session_5h", usedPercent: 30, sampledAt: Date(timeIntervalSince1970: 1_500), source: .provider),
            QuotaBar(id: "weekly_all", usedPercent: 60, sampledAt: Date(timeIntervalSince1970: 1_500), source: .provider),
            QuotaBar(id: "daily", usedPercent: 1, sampledAt: Date(timeIntervalSince1970: 1_500), source: .provider)
        ])
        let merged = QuotaMerge.bars(passive: passive, active: active)
        #expect(merged.map(\.id) == ["session_5h", "daily", "weekly_all", "weekly_fable"])
        #expect(merged.map(\.usedPercent) == [10, 1, 60, 5])
        #expect(merged.map(\.source) == [.proxy, .provider, .provider, .proxy])
    }

    @Test func laterRefreshesKeepPlanAndResetsTheyDidNotFetch() {
        let first = ActiveQuota(credentialID: "c", provider: "claude", observedAt: .distantPast, windows: [QuotaBar(id: "weekly_all", usedPercent: 1)], plan: "max", resets: ManualResets(remaining: 1))
        let automatic = ActiveQuota(credentialID: "c", provider: "claude", observedAt: .now, windows: [QuotaBar(id: "weekly_all", usedPercent: 9)])
        let merged = automatic.superseding(first, read: [.windows])
        #expect(merged.plan == "max")
        #expect(merged.resets == ManualResets(remaining: 1))
        #expect(merged.windows.first?.usedPercent == 9)
    }

    @Test func planListsWhatWillBeContactedAndTheRisks() {
        var limited = ActiveRefreshState()
        limited.nextAllowedAt = Date(timeIntervalSince1970: 1_794_710_000)
        limited.rateLimitedUntil = limited.nextAllowedAt
        let states: [String: ActiveRefreshState] = ["c1": limited]
        let plan = LimitsRefreshPlan.make(
            targets: [target("claude", "c1"), target("claude", "c2"), target("xai", "g1"), target("antigravity", "a1", projectID: "p"), target("gemini-cli", "gc")],
            states: states,
            now: Date(timeIntervalSince1970: 1_794_700_000)
        )
        #expect(plan.groups.map(\.provider) == ["claude", "antigravity", "xai"])
        #expect(plan.groups.first?.requests == [.usage, .profile, .resetGrants])
        #expect(plan.waiting.map(\.credentialID) == ["c1"])
        #expect(plan.waiting.first?.because == .rateLimited)
        #expect(plan.mayRunPaidCompletion)
        #expect(plan.usesUnofficialGoogleEndpoints)
        #expect(plan.unsupportedProviders == ["gemini-cli"])
        #expect(plan.maximumRequests == 3 + 4 + 6)
    }

    @Test func pooledCapacityAndSnapshotsUseProviderResults() throws {
        let now = Date()
        let credential = Credential(name: "x.json", authIndex: "x1", provider: "xai")
        let active = ActiveQuota(credentialID: "x.json", provider: "xai", observedAt: now, windows: [QuotaBar(id: "weekly_all", usedPercent: 40, sampledAt: now, source: .provider)])
        let snapshot = HeadroomSnapshot.management(.demo(), credentials: [credential], active: ["x.json": active], now: now)
        let pool = try #require(snapshot.pools(at: now).first)
        #expect(pool.window(.weekly)?.remainingPercent == 60)
        let decoded = try JSONDecoder.wire().decode(HeadroomSnapshot.self, from: JSONEncoder.wire().encode(snapshot))
        #expect(decoded.poolAccounts.first?.bars.first?.source == .provider)
    }
}

@Suite("Provider limit refresh: demo")
struct ActiveRefreshDemoTests {
    @Test func demoServerAnswersWithFakeProviderDataAndNoNetwork() async throws {
        let transport = DemoTransport()
        let client = ManagementClient(baseURL: ServerProfile.demoBaseURL, managementKey: DemoTransport.secret, transport: transport)
        let credentials = try await client.credentials().value.files
        let targets = credentials.map { ActiveTarget(credential: $0, now: .now) }
        let plan = LimitsRefreshPlan.make(targets: targets, states: [:], now: .now)
        #expect(plan.mayRunPaidCompletion)
        #expect(plan.unsupportedProviders == ["gemini-cli"])

        let store = MemoryActiveRefreshStore()
        let results = await ActiveRefreshCoordinator(store: store, pause: { _ in }).refresh(targets, server: ActiveRefreshServer(serverID: ServerProfile.demoID, baseURL: ServerProfile.demoBaseURL, generation: 0), mode: .manual) {
            try await client.apiCall($0, hooks: $1)
        }
        let refreshed = results.compactMap(\.outcome.quota)
        #expect(Set(refreshed.map(\.provider)) == ["claude", "codex", "xai"])
        let grok = try #require(refreshed.first { $0.provider == "xai" })
        #expect(grok.plan == "SuperGrok")
        #expect(grok.note == nil)
        let studio = try #require(refreshed.first { $0.credentialID == "claude-studio.json" })
        #expect(studio.plan == "max 20x")
        #expect(studio.resets?.remaining == 2)
    }
}
