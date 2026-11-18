import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Pooled capacity")
struct PooledCapacityTests {
    let now = date("2026-11-14T10:00:00Z")

    func claude(
        _ name: String,
        session: Double?,
        weekly: Double?,
        sessionReset: String = "2026-11-14T12:00:00Z",
        weeklyReset: String = "2026-11-18T00:00:00Z",
        sessionStatus: String? = nil,
        disabled: Bool = false,
        cooldownUntil: String? = nil
    ) -> Credential {
        var signals: [String: String] = [:]
        if let session {
            signals["Anthropic-Ratelimit-Unified-5h-Utilization"] = String(session / 100)
            signals["Anthropic-Ratelimit-Unified-5h-Reset"] = sessionReset
        }
        if let sessionStatus { signals["Anthropic-Ratelimit-Unified-5h-Status"] = sessionStatus }
        if let weekly {
            signals["Anthropic-Ratelimit-Unified-7d-Utilization"] = String(weekly / 100)
            signals["Anthropic-Ratelimit-Unified-7d-Reset"] = weeklyReset
        }
        return Credential(
            name: name,
            authIndex: name,
            provider: "claude",
            disabled: disabled,
            quota: QuotaObservation(signals: signals, observedAt: date("2026-11-14T09:30:00Z")),
            cooldowns: cooldownUntil.map { [Cooldown(scope: "credential", reason: "quota", retryAt: date($0))] } ?? []
        )
    }

    func pools(_ credentials: [Credential]) -> [ProviderPool] {
        PooledCapacity.pools(credentials.map { PoolAccount(credential: $0, now: now) }, now: now)
    }

    @Test func threeAccountsGiveThreeHundredPercentCapacity() throws {
        let pool = try #require(pools([
            claude("a", session: 20, weekly: 10),
            claude("b", session: 50, weekly: 40),
            claude("c", session: 43, weekly: 70)
        ]).first)
        let session = try #require(pool.window(.session5h))
        let weekly = try #require(pool.window(.weekly))
        #expect(pool.accounts == 3)
        #expect(session.capacityPercent == 300)
        #expect(session.remainingPercent == 187)
        #expect(weekly.remainingPercent == 180)
        #expect(session.unknownAccounts == 0)
        #expect(session.latestSampleAt == date("2026-11-14T09:30:00Z"))
    }

    @Test func blockClearsAtOnceWhenEveryBlockedAccountUnblocksTogetherDespiteDecimalPercents() throws {
        let unblock = date("2026-11-20T11:00:00Z")
        let later = date("2026-11-21T11:00:00Z")
        func account(_ fablePercentUsed: Double, weeklyRejectedUntil: Date?) -> PoolAccount {
            var bars = [QuotaBar(id: "weekly_fable", usedPercent: fablePercentUsed, resetsAt: date("2026-11-22T00:00:00Z"))]
            bars.append(weeklyRejectedUntil.map { QuotaBar(id: "weekly_all", usedPercent: 100, status: "rejected", resetsAt: $0) }
                ?? QuotaBar(id: "weekly_all", usedPercent: 10, resetsAt: date("2026-11-22T00:00:00Z")))
            return PoolAccount(provider: "claude", availability: .available, bars: bars)
        }
        let together = try #require(PooledCapacity.pools([
            account(66.7, weeklyRejectedUntil: nil),
            account(41.3, weeklyRejectedUntil: unblock),
            account(55.9, weeklyRejectedUntil: unblock)
        ], now: now).first?.window(.weeklyFable))
        #expect(together.hasBlockedQuota)
        #expect(together.blockClearsAtOnce)
        #expect(together.blockedUntil == unblock)

        let staggered = try #require(PooledCapacity.pools([
            account(66.7, weeklyRejectedUntil: nil),
            account(41.3, weeklyRejectedUntil: unblock),
            account(55.9, weeklyRejectedUntil: later)
        ], now: now).first?.window(.weeklyFable))
        #expect(!staggered.blockClearsAtOnce)
        #expect(staggered.blockedUntil == unblock)
    }

    @Test func disabledAccountsLeaveTheCapacity() throws {
        let window = try #require(pools([
            claude("a", session: 20, weekly: 10),
            claude("b", session: 0, weekly: 0, disabled: true)
        ]).first?.window(.session5h))
        #expect(window.capacityPercent == 100)
        #expect(window.remainingPercent == 80)
    }

    @Test func coolingAccountKeepsItsQuotaButBlocksItUntilTheCooldownEnds() throws {
        let pool = try #require(pools([
            claude("a", session: 20, weekly: 10),
            claude("b", session: 0, weekly: 0, cooldownUntil: "2026-11-14T10:30:00Z")
        ]).first)
        let window = try #require(pool.window(.session5h))
        #expect(window.capacityPercent == 200)
        #expect(window.remainingPercent == 180)
        #expect(window.usablePercent == 80)
        #expect(window.blockedPercent == 100)
        #expect(window.blockedUntil == date("2026-11-14T10:30:00Z"))
        #expect(window.blockReason == .cooldown)
        #expect(window.nextIncreaseAt == date("2026-11-14T10:30:00Z"))

        let account = PoolAccount(credential: claude("b", session: 0, weekly: 0, cooldownUntil: "2026-11-14T10:30:00Z"), now: now)
        let later = try #require(PooledCapacity.pools([account], now: date("2026-11-14T10:31:00Z")).first?.window(.session5h))
        #expect(later.remainingPercent == 100)
        #expect(later.usablePercent == 100)
        #expect(!later.hasBlockedQuota)
    }

    @Test func accountThatHitTheLimitContributesNothingUntilTheReset() throws {
        let window = try #require(pools([
            claude("a", session: 97, weekly: 10, sessionStatus: "rejected"),
            claude("b", session: 100, weekly: 10)
        ]).first?.window(.session5h))
        #expect(window.remainingPercent == 0)
        #expect(window.nextIncreaseAt == date("2026-11-14T12:00:00Z"))
    }

    @Test func windowAtItsLimitBlocksTheAccountsOtherWindowsUntilItResets() throws {
        let pool = try #require(pools([
            claude("a", session: 100, weekly: 40),
            claude("b", session: 30, weekly: 10)
        ]).first)
        let weekly = try #require(pool.window(.weekly))
        #expect(weekly.remainingPercent == 150)
        #expect(weekly.usablePercent == 90)
        #expect(weekly.blockedUntil == date("2026-11-14T12:00:00Z"))
        #expect(weekly.blockReason == .windowAtLimit("session_5h"))
        #expect(pool.usableAccounts == 1)
    }

    @Test func passedResetCountsAsAFreshWindow() throws {
        let window = try #require(pools([
            claude("a", session: 100, weekly: 10, sessionReset: "2026-11-14T09:00:00Z"),
            claude("b", session: 40, weekly: 10)
        ]).first?.window(.session5h))
        #expect(window.remainingPercent == 160)
    }

    @Test func accountWithoutASampleIsUnknownNotZeroOrFull() throws {
        let pool = try #require(pools([
            claude("a", session: 30, weekly: 10),
            claude("b", session: nil, weekly: nil)
        ]).first)
        let window = try #require(pool.window(.session5h))
        #expect(window.capacityPercent == 200)
        #expect(window.remainingPercent == 70)
        #expect(window.unknownAccounts == 1)
        #expect(window.knownAccounts == 1)
        #expect(window.accountsWithoutRunningWindow == 0)
    }

    @Test func usableAccountWithoutAFiveHourBarCountsAsFullAndABlockedOneIsLeftOut() throws {
        let pool = try #require(pools([
            claude("a", session: 30, weekly: 10),
            claude("b", session: nil, weekly: 20),
            claude("c", session: nil, weekly: 50, cooldownUntil: "2026-11-14T11:00:00Z")
        ]).first)
        let session = try #require(pool.window(.session5h))
        #expect(session.accountsCountedAsFull == 1)
        #expect(session.accountsWithoutRunningWindow == 1)
        #expect(session.unknownAccounts == 0)
        #expect(session.capacityPercent == 200)
        #expect(session.remainingPercent == 170)
        #expect(session.usablePercent == 170)
        #expect(session.remainingShareOfKnown == 0.85)
        let weekly = try #require(pool.window(.weekly))
        #expect(weekly.capacityPercent == 300)
        #expect(weekly.remainingPercent == 220)
        #expect(weekly.usablePercent == 170)
        #expect(weekly.accountsWithoutRunningWindow == 0)
    }

    @Test func explicitIdleFiveHourWindowCountsAsFull() throws {
        let idle = Credential(name: "idle", authIndex: "idle", provider: "claude", quota: QuotaObservation(signals: [
            "Anthropic-Ratelimit-Unified-5h-Utilization": "0",
            "Anthropic-Ratelimit-Unified-7d-Utilization": "0.2",
            "Anthropic-Ratelimit-Unified-7d-Reset": "2026-11-18T00:00:00Z"
        ], observedAt: now))
        let window = try #require(pools([claude("a", session: 30, weekly: 10), idle]).first?.window(.session5h))
        #expect(window.remainingPercent == 170)
        #expect(window.capacityPercent == 200)
        #expect(window.accountsWithoutRunningWindow == 0)
        #expect(AccountSummary(credential: idle, now: now).fiveHourWindow(at: now) == .startsOnUse)
    }

    @Test func rejectedWindowWithoutUtilisationContributesNothing() throws {
        let rejected = Credential(name: "r", authIndex: "r", provider: "claude", quota: QuotaObservation(signals: [
            "Anthropic-Ratelimit-Unified-5h-Status": "rejected",
            "Anthropic-Ratelimit-Unified-5h-Reset": "2026-11-14T12:00:00Z",
            "Anthropic-Ratelimit-Unified-7d-Utilization": "0.2"
        ], observedAt: now))
        let window = try #require(pools([claude("a", session: 30, weekly: 10), rejected]).first?.window(.session5h))
        #expect(window.remainingPercent == 70)
        #expect(window.unknownAccounts == 0)
        #expect(window.nextIncreaseAt == date("2026-11-14T12:00:00Z"))
    }

    @Test func providerCountsSeparateAllAccountsFromUsableOnes() throws {
        var needsSignIn = claude("d", session: 10, weekly: 10)
        needsSignIn.requiresSignIn = true
        let pool = try #require(pools([
            claude("a", session: 30, weekly: 10),
            claude("b", session: 0, weekly: 0, disabled: true),
            claude("c", session: 0, weekly: 0, cooldownUntil: "2026-11-14T11:00:00Z"),
            needsSignIn
        ]).first)
        #expect(pool.totalAccounts == 4)
        #expect(pool.accounts == 3)
        #expect(pool.usableAccounts == 1)
        let afterCooldown = PooledCapacity.pools(
            [claude("c", session: 0, weekly: 0, cooldownUntil: "2026-11-14T11:00:00Z")].map { PoolAccount(credential: $0, now: now) },
            now: date("2026-11-14T11:30:00Z")
        )
        #expect(afterCooldown.first?.usableAccounts == 1)
    }

    @Test func accountWaitingForSignInIsBlockedWithoutAnEndTime() throws {
        var needsSignIn = claude("b", session: 0, weekly: 0, sessionReset: "2026-11-14T09:00:00Z")
        needsSignIn.status = "error"
        needsSignIn.requiresSignIn = true
        let window = try #require(pools([claude("a", session: 50, weekly: 10, sessionReset: "2026-11-14T13:00:00Z"), needsSignIn]).first?.window(.session5h))
        #expect(window.remainingPercent == 150)
        #expect(window.usablePercent == 50)
        #expect(window.blockedUntil == nil)
        #expect(window.blockReason == .signIn)
        #expect(window.nextIncreaseAt == date("2026-11-14T13:00:00Z"))
    }

    @Test func nextIncreaseIsTheSoonestResetOfAPartlyUsedAccount() throws {
        let window = try #require(pools([
            claude("a", session: 0, weekly: 10, sessionReset: "2026-11-14T10:10:00Z"),
            claude("b", session: 40, weekly: 10, sessionReset: "2026-11-14T11:00:00Z"),
            claude("c", session: 60, weekly: 10, sessionReset: "2026-11-14T10:45:00Z")
        ]).first?.window(.session5h))
        #expect(window.nextIncreaseAt == date("2026-11-14T10:45:00Z"))
    }

    @Test func bindingWindowAndMostConstrainedProvider() throws {
        let codex = Credential(name: "x", authIndex: "x", provider: "codex", quota: QuotaObservation(signals: [
            "X-Codex-Primary-Used-Percent": "90",
            "X-Codex-Primary-Window-Minutes": "10080"
        ], observedAt: now))
        let all = pools([claude("a", session: 20, weekly: 70), claude("b", session: 50, weekly: 40), codex])
        #expect(all.map(\.provider) == ["claude", "codex"])
        #expect(all[0].bindingWindow?.window == .weekly)
        #expect(PooledCapacity.mostConstrained(all)?.provider == "codex")
    }

    @Test func rankingFollowsWhatIsUsableNowWithTheSumAsTieBreaker() throws {
        let other = Credential(name: "x", authIndex: "x", provider: "codex", quota: QuotaObservation(signals: [
            "X-Codex-Primary-Used-Percent": "50",
            "X-Codex-Primary-Window-Minutes": "10080"
        ], observedAt: now))
        let all = pools([
            claude("a", session: 10, weekly: 10, cooldownUntil: "2026-11-14T10:30:00Z"),
            claude("b", session: 10, weekly: 10, cooldownUntil: "2026-11-14T10:30:00Z"),
            other
        ])
        #expect(all[0].window(.session5h)?.remainingShareOfKnown == 0.9)
        #expect(all[0].window(.session5h)?.usableShareOfKnown == 0)
        #expect(PooledCapacity.mostConstrained(all)?.provider == "claude")

        let tied = try #require(pools([
            claude("a", session: 40, weekly: 10, cooldownUntil: "2026-11-14T10:30:00Z"),
            claude("b", session: 10, weekly: 10, cooldownUntil: "2026-11-14T10:30:00Z")
        ]).first)
        #expect(tied.bindingWindow?.window == .session5h)
    }

    @Test func providerWithoutSignalsHasAccountsButNoWindows() throws {
        let pool = try #require(pools([Credential(name: "g", authIndex: "g", provider: "gemini-cli")]).first)
        #expect(pool.accounts == 1)
        #expect(pool.windows.isEmpty)
        #expect(pool.bindingWindow == nil)
    }

    @Test func fleetCredentialsPoolTheSameWay() throws {
        let json = #"""
        {"object":"fleet.limits","generated_at":"2026-11-14T10:00:00Z","credentials":[
          {"label":"c1","provider":"claude","state":"active","cooldowns":[],
           "bars":[{"id":"session_5h","percent":30,"resets_at":"2026-11-14T12:00:00Z","reset_passed":false},
                   {"id":"weekly_fable","percent":50,"resets_at":"2026-11-18T00:00:00Z","reset_passed":false}]},
          {"label":"c2","provider":"claude","state":"active","cooldowns":[],
           "bars":[{"id":"session_5h","percent":100,"status":"rejected","resets_at":"2026-11-14T09:00:00Z","reset_passed":true}]},
          {"label":"c3","provider":"claude","state":"cooldown",
           "cooldowns":[{"scope":"credential","reason":"quota","until":"2026-11-14T11:00:00Z"}],
           "bars":[{"id":"session_5h","percent":10,"resets_at":"2026-11-14T12:00:00Z","reset_passed":false}]},
          {"label":"c4","provider":"claude","state":"disabled","cooldowns":[],"bars":[]}
        ],"summary":{}}
        """#
        let limits = try JSONDecoder.wire().decode(FleetLimits.self, from: Data(json.utf8))
        let snapshot = HeadroomSnapshot.clientKey(.demo(authMode: .clientKey), limits: limits, now: now)
        let pool = try #require(snapshot.pools(at: now).first)
        let session = try #require(pool.window(.session5h))
        let weeklyModel = try #require(pool.window(.weeklyFable))
        #expect(pool.accounts == 3)
        #expect(session.remainingPercent == 260)
        #expect(session.usablePercent == 170)
        #expect(session.nextIncreaseAt == date("2026-11-14T11:00:00Z"))
        #expect(weeklyModel.remainingPercent == 50)
        #expect(weeklyModel.unknownAccounts == 2)
    }

    func fleetAccount(state: String, cooldowns: String) throws -> PoolAccount {
        let json = #"{"label":"c","provider":"claude","state":"\#(state)","cooldowns":[\#(cooldowns)],"bars":[{"id":"session_5h","percent":40}]}"#
        return PoolAccount(fleet: try JSONDecoder.wire().decode(FleetCredential.self, from: Data(json.utf8)))
    }

    @Test func fleetCooldownOnlyBlocksForCredentialWideCooldowns() throws {
        let modelOnly = try fleetAccount(state: "cooldown", cooldowns: #"{"scope":"model","model":"m","reason":"quota","until":"2026-11-14T11:00:00Z"}"#)
        let openEnded = try fleetAccount(
            state: "cooldown",
            cooldowns: #"{"scope":"credential","reason":"quota","until":null},{"scope":"credential","reason":"quota","until":"2026-11-14T11:00:00Z"}"#
        )
        let dated = try fleetAccount(state: "cooldown", cooldowns: #"{"scope":"credential","reason":"quota","until":"2026-11-14T11:00:00Z"}"#)
        #expect(modelOnly.availability == .available)
        #expect(openEnded.availability == .blocked(until: nil))
        #expect(dated.availability == .blocked(until: date("2026-11-14T11:00:00Z")))
        #expect(openEnded.remainingPercent(in: "session_5h", at: date("2026-11-14T12:00:00Z")) == 60)
        #expect(openEnded.usablePercent(in: "session_5h", at: date("2026-11-14T12:00:00Z")) == 0)
    }

    @Test func passedFleetResetDropsTheRejectedStatus() throws {
        let json = #"{"id":"session_5h","percent":100,"status":"rejected","resets_at":"2026-11-14T09:00:00Z","reset_passed":true}"#
        let bar = try JSONDecoder.wire().decode(FleetBar.self, from: Data(json.utf8)).quotaBar
        #expect(bar.status == nil)
        #expect(PoolAccount(provider: "claude", availability: .available, bars: [bar]).remainingPercent(in: "session_5h", at: now) == 100)
    }

    @Test func accountNeedingSignInStaysBlockedAfterItsCooldownEnds() throws {
        var needsSignIn = claude("b", session: 10, weekly: 10, cooldownUntil: "2026-11-14T10:30:00Z")
        needsSignIn.requiresSignIn = true
        let snapshot = HeadroomSnapshot.management(.demo(), credentials: [needsSignIn], now: now)
        let later = try #require(snapshot.pools(at: date("2026-11-14T11:00:00Z")).first?.window(.session5h))
        #expect(later.remainingPercent == 90)
        #expect(later.usablePercent == 0)
        #expect(later.blockReason == .signIn)
        #expect(later.nextIncreaseAt == date("2026-11-14T12:00:00Z"))
    }

    @Test func growthTimeSkipsACooldownEndThatLeavesTheWindowExhausted() throws {
        let pool = try #require(pools([
            claude("a", session: 100, weekly: 100, cooldownUntil: "2026-11-14T11:00:00Z"),
            claude("b", session: 100, weekly: 30, sessionReset: "2026-11-14T13:00:00Z")
        ]).first)
        #expect(pool.window(.session5h)?.nextIncreaseAt == date("2026-11-14T12:00:00Z"))

        let exhausted = try #require(pools([claude("a", session: 100, weekly: 100, cooldownUntil: "2026-11-14T11:00:00Z")]).first)
        #expect(exhausted.window(.weekly)?.nextIncreaseAt == date("2026-11-18T00:00:00Z"))
        let partlyUsed = try #require(pools([claude("a", session: 100, weekly: 30, cooldownUntil: "2026-11-14T11:00:00Z")]).first)
        #expect(partlyUsed.window(.weekly)?.nextIncreaseAt == date("2026-11-14T12:00:00Z"))
        #expect(partlyUsed.window(.weekly)?.blockedUntil == date("2026-11-14T12:00:00Z"))
    }

    @Test func mostConstrainedFallbackSkipsProvidersWithoutAccounts() {
        let empty = ProviderPool(provider: "claude", accounts: 0, windows: [])
        let unsampled = ProviderPool(provider: "gemini-cli", accounts: 2, windows: [])
        #expect(PooledCapacity.mostConstrained([empty, unsampled])?.provider == "gemini-cli")
        #expect(PooledCapacity.mostConstrained([empty]) == nil)
    }

    @Test func headlineWindowsKeepTheBindingWindow() {
        func window(_ id: String, remaining: Double) -> PooledWindow {
            PooledWindow(barID: id, accounts: 1, unknownAccounts: 0, remainingPercent: remaining, nextIncreaseAt: nil, latestSampleAt: nil)
        }
        let modelWindowBinds = ProviderPool(provider: "claude", accounts: 1, windows: [window("session_5h", remaining: 80), window("weekly_all", remaining: 60), window("weekly_fable", remaining: 5)])
        #expect(modelWindowBinds.headlineWindows(limit: 2).map(\.barID) == ["session_5h", "weekly_fable"])
        let usual = ProviderPool(provider: "claude", accounts: 1, windows: [window("session_5h", remaining: 30), window("weekly_all", remaining: 60), window("weekly_fable", remaining: 90)])
        #expect(usual.headlineWindows(limit: 2).map(\.barID) == ["session_5h", "weekly_all"])
        let minutesOnly = ProviderPool(provider: "x", accounts: 1, windows: [window("window_60m", remaining: 30), window("window_1440m", remaining: 60)])
        #expect(minutesOnly.headlineWindows(limit: 2).map(\.barID) == ["window_60m", "window_1440m"])
    }

    @Test func snapshotRecomputesPoolsAtDisplayTime() throws {
        let snapshot = HeadroomSnapshot.management(.demo(), credentials: [claude("a", session: 90, weekly: 10, sessionReset: "2026-11-14T10:05:00Z")], now: now)
        #expect(snapshot.pools(at: now).first?.window(.session5h)?.remainingPercent == 10)
        #expect(snapshot.pools(at: date("2026-11-14T10:06:00Z")).first?.window(.session5h)?.remainingPercent == 100)
    }

    @Test func demoServerHasPooledCapacity() async throws {
        let snapshot = try await HeadroomLoader.load(profile: .demo(), secret: DemoTransport.secret, transport: DemoTransport.shared)
        #expect(snapshot.pools(at: .now).contains { $0.accounts > 1 && !$0.windows.isEmpty })
    }
}
