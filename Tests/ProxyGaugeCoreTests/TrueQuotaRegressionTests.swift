import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Authoritative quota readings and paid-key approval")
struct TrueQuotaRegressionTests {
    @Test func authoritativeAbsenceSuppressesOlderProxyFiveHourBars() async throws {
        let (outcome, _) = await ActiveQuotaParsingTests().refresh(target("claude", "c1")) { url in
            url == ClaudeAdapter.usageURL ? .json(#"{"five_hour":null,"seven_day":{"utilization":10}}"#) : nil
        }
        let quota = try #require(outcome?.quota)
        let saved = try JSONDecoder().decode(ActiveQuota.self, from: JSONEncoder().encode(quota))
        let earlier = QuotaBar(id: "session_5h", usedPercent: 20, sampledAt: activeStart.addingTimeInterval(-1), source: .proxy)
        var later = earlier
        later.sampledAt = activeStart.addingTimeInterval(1)
        let merged = QuotaMerge.bars(passive: [earlier], active: saved)
        #expect(merged.map(\.id) == ["weekly_all"])
        let account = AccountSummary(id: "c1", provider: "claude", label: "c1", state: .active, bars: merged)
        #expect(account.resets(at: activeStart).map(\.barID) == ["weekly_all"])
        #expect(AccountOrder.routerReadings(account, now: activeStart)?.short == nil)
        #expect(QuotaMerge.bars(passive: [later], active: saved).first == later)
    }

    @Test(arguments: [false, true])
    func legacyCodexWindowStaysOnTheCardButOutOfRouterInputs(reportsDuration: Bool) async throws {
        let duration = reportsDuration ? #", "limit_window_seconds": 18000"# : ""
        let body = """
        {"rate_limit":{"primary_window":{"used_percent":90\(duration)},"secondary_window":{"used_percent":15,"limit_window_seconds":604800}}}
        """
        let (outcome, _) = await ActiveQuotaParsingTests().refresh(target("codex", "x1")) { url in
            url == CodexAdapter.usageURL ? .json(body) : nil
        }
        let quota = try #require(outcome?.quota)
        let account = AccountSummary(id: "x1", provider: "codex", label: "x1", state: .active, bars: quota.windows)
        let slots = QuotaSlots.slots(provider: "codex", accounts: [account])
        #expect(QuotaSlots.reading(account, slot: slots[0], at: activeStart).remainingPercent == 10)
        let readings = try #require(AccountOrder.routerReadings(account, now: activeStart))
        #expect(readings.weekly?.usedPercent == 15)
        #expect(readings.short?.usedPercent == (reportsDuration ? 90 : nil))
    }

    @Test func expiredTimestampAloneDoesNotMakeAQuotaReading() throws {
        let past = activeStart.addingTimeInterval(-1)
        let account = AccountSummary(id: "a", provider: "claude", label: "a", state: .active, bars: [
            QuotaBar(id: "session_5h", usedPercent: nil, resetsAt: past),
            QuotaBar(id: "weekly_all", usedPercent: nil, resetsAt: past),
            QuotaBar(id: "weekly_fable", usedPercent: 30, resetsAt: past)
        ])
        let pools = QuotaSlots.pools(provider: "claude", accounts: [account], at: activeStart).pools
        #expect(pools.map(\.remainingPercent) == [nil, nil, 100])
        #expect(account.resets(at: activeStart).map(\.remainingPercent) == [nil, nil, 100])
    }

    @Test func claudeClearsFactsOnlyWhenTheAuthoritativeEndpointAnswers() async throws {
        let store = MemoryActiveRefreshStore()
        let clock = TestClock(activeStart)
        let parsing = ActiveQuotaParsingTests()
        let account = target("claude", "c1")
        _ = await parsing.refresh(account, store: store, clock: clock) { url in
            url == ClaudeAdapter.usageURL ? .json(#"{"seven_day":{"utilization":10},"extra_usage":{"is_enabled":true}}"#) : nil
        }
        let first = try #require(store.activeQuotas(proxy: activeServer.proxy)["c1"])
        #expect(first.plan != nil)
        #expect(first.extraUsage?.isEnabled == true)

        clock.advance(by: 10 * 60)
        _ = await parsing.refresh(account, store: store, clock: clock) { url in
            switch url {
            case ClaudeAdapter.usageURL: .json(#"{"seven_day":{"utilization":11}}"#)
            case ClaudeAdapter.profileURL: .status(503)
            default: nil
            }
        }
        let partial = try #require(store.activeQuotas(proxy: activeServer.proxy)["c1"])
        #expect(partial.plan == first.plan)
        #expect(partial.sampledAt(for: .plan) == first.sampledAt(for: .plan))
        #expect(partial.extraUsage == nil)

        clock.advance(by: 10 * 60)
        _ = await parsing.refresh(account, store: store, clock: clock) { url in
            url == ClaudeAdapter.profileURL ? .json("{}") : nil
        }
        #expect(store.activeQuotas(proxy: activeServer.proxy)["c1"]?.plan == nil)
    }

    @Test func paidKeyApprovalRunsOnlyTheMissingPhaseAndHonorsProxyBackoff() async throws {
        let store = MemoryActiveRefreshStore()
        let clock = TestClock(activeStart)
        let refresher = coordinator(store, clock: clock)
        let account = target("xai", "g1")
        let stub = UpstreamStub { _, _ in .json("{}") }
        let initial = await run(refresher, [account], mode: .manualReadOnly, through: stub)
        let attempt = try #require(initial.first?.paidKeyConsentAttemptAt)
        let approval = ActiveRefreshMode.approvedSurface(paidKeyAttempts: [account.id: attempt])
        #expect(stub.upstreamURLs == [XAIAdapter.weeklyBillingURL, XAIAdapter.monthlyBillingURL])
        let wait = try #require(store.activeRefreshStates(proxy: activeServer.proxy)[account.id]?.nextAllowedAt)
        #expect(wait > activeStart)

        let proxyWait = activeStart.addingTimeInterval(30)
        store.saveProxyRefusalBackoff(ProxyRefusalBackoff(consecutiveRefusals: 1, until: proxyWait), proxy: activeServer.proxy)
        let paused = await run(refresher, [account], mode: approval, through: stub)
        #expect(paused.first?.outcome == .waiting(until: proxyWait, because: .proxyRefused))
        #expect(stub.upstreamURLs.count == 2)
        clock.advance(by: 31)

        let resumed = await run(refresher, [account], mode: approval, through: stub)
        #expect(resumed.first?.outcome.quota?.note == .paidKeyAnswered)
        #expect(Array(stub.upstreamURLs.dropFirst(2)) == [XAIAdapter.apiProfileURL, XAIAdapter.completionURL])
        let replay = await run(refresher, [account], mode: approval, through: stub)
        #expect(replay.first?.outcome == .skipped(.approvalExpired))
        #expect(stub.upstreamURLs.count == 4)
    }

    @Test func demoIncludesAbsentWindowsAndUnusableGrants() async throws {
        let profile = ServerProfile.demo()
        let demo = DemoTransport(clock: { activeStart })
        let client = ManagementClient(baseURL: profile.baseURL, managementKey: DemoTransport.secret, transport: demo)
        let credentials = try await client.credentials().value.files
        let lab = try #require(credentials.first { $0.name == "claude-lab.json" })
        let backup = try #require(credentials.first { $0.name == "codex-backup.json" })
        let team = try #require(credentials.first { $0.name == "claude-team.json" })
        for account in [lab, backup] {
            #expect(!account.quotaBars.contains { $0.window == .session5h })
            var target = ActiveTarget(credential: account, now: activeStart)
            target.disabled = false
            let store = MemoryActiveRefreshStore()
            let results = await coordinator(store, clock: TestClock(activeStart)).refresh([target], server: activeServer, mode: .manual) {
                try await client.apiCall($0, hooks: $1)
            }
            let quota = try #require(results.first?.outcome.quota)
            #expect(!quota.windows.contains { $0.window == .session5h })
        }
        let target = ActiveTarget(credential: team, now: activeStart)
        let results = await coordinator(MemoryActiveRefreshStore(), clock: TestClock(activeStart)).refresh([target], server: activeServer, mode: .manual) {
            try await client.apiCall($0, hooks: $1)
        }
        #expect(results.first?.outcome.quota?.resets?.remaining == 0)
        #expect(results.first?.outcome.quota?.resets?.total == 3)
    }
}
