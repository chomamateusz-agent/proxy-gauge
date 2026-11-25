import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Panel quota: plan weights, fixed slots and provider pools")
struct PanelQuotaTests {
    let now = date("2026-11-24T10:00:00Z")

    func claude(
        _ id: String,
        plan: String? = "max 20x",
        session: Double? = 20,
        weekly: Double? = 40,
        fable: Double? = nil,
        state: CredentialState = .active,
        requiresSignIn: Bool = false,
        endsAt: Date? = nil,
        provider: String = "claude"
    ) -> AccountSummary {
        var bars: [QuotaBar] = []
        if let session { bars.append(QuotaBar(id: "session_5h", usedPercent: session, resetsAt: now.addingTimeInterval(3_600))) }
        if let weekly { bars.append(QuotaBar(id: "weekly_all", usedPercent: weekly, resetsAt: now.addingTimeInterval(86_400))) }
        if let fable { bars.append(QuotaBar(id: "weekly_fable", usedPercent: fable, resetsAt: now.addingTimeInterval(86_400))) }
        var account = AccountSummary(id: id, provider: provider, label: id, state: state, plan: plan, bars: bars, requiresSignIn: requiresSignIn)
        account.endsAt = endsAt
        return account
    }

    @Test func planMultipliersFollowThePanel() {
        #expect(PlanWeight.multiplier(provider: "claude", plan: "max 20x") == 20)
        #expect(PlanWeight.multiplier(provider: "claude", plan: "plan_max20") == 20)
        #expect(PlanWeight.multiplier(provider: "claude", plan: "max 5x") == 5)
        #expect(PlanWeight.multiplier(provider: "claude", plan: "plan_max5") == 5)
        #expect(PlanWeight.multiplier(provider: "claude", plan: "pro") == 1)
        #expect(PlanWeight.multiplier(provider: "claude", plan: "max") == nil)
        #expect(PlanWeight.multiplier(provider: "claude", plan: "team") == nil)
        #expect(PlanWeight.multiplier(provider: "claude", plan: nil) == nil)
        #expect(PlanWeight.multiplier(provider: "codex", plan: "pro") == nil)
    }

    @Test func poolIsWeightedByPlanWhenEveryClaudePlanIsKnown() throws {
        let accounts = [
            claude("big", plan: "max 20x", weekly: 90),
            claude("mid", plan: "max 5x", weekly: 0),
            claude("small", plan: "pro", weekly: 50)
        ]
        let result = QuotaSlots.pools(provider: "claude", accounts: accounts, at: now)
        #expect(result.weighted)
        let weekly = try #require(result.pools.first { $0.slot.barID == "weekly_all" })
        let expected = (20.0 * 10 + 5 * 100 + 1 * 50) / 26
        #expect(abs((weekly.remainingPercent ?? 0) - expected) < 0.0001)
        #expect(weekly.covered == 3)
        #expect(weekly.total == 3)
    }

    @Test func oneUnknownPlanFallsBackToAPlainAverage() throws {
        let accounts = [claude("big", plan: "max 20x", weekly: 90), claude("unknown", plan: "max", weekly: 10)]
        let result = QuotaSlots.pools(provider: "claude", accounts: accounts, at: now)
        #expect(!result.weighted)
        let weekly = try #require(result.pools.first { $0.slot.barID == "weekly_all" })
        #expect(weekly.remainingPercent == 50)
    }

    @Test func disabledEndedAndUnloadedAccountsStayOutOfThePercentButCountInTheTotal() throws {
        let accounts = [
            claude("live", weekly: 30),
            claude("off", weekly: 0, state: .disabled),
            claude("gone", weekly: 0, endsAt: now.addingTimeInterval(-60)),
            claude("empty", session: nil, weekly: nil)
        ]
        let result = QuotaSlots.pools(provider: "claude", accounts: accounts, at: now)
        let weekly = try #require(result.pools.first { $0.slot.barID == "weekly_all" })
        #expect(weekly.remainingPercent == 70)
        #expect(weekly.covered == 1)
        #expect(weekly.total == 4)
        #expect(result.loaded == 3)
        #expect(result.accounts == 4)
    }

    @Test func slotWithoutAnyReadingHasNoPercent() throws {
        let result = QuotaSlots.pools(provider: "claude", accounts: [claude("a")], at: now)
        let fable = try #require(result.pools.first { $0.slot.window == .weeklyFable })
        #expect(fable.remainingPercent == nil)
        #expect(fable.covered == 0)
        #expect(fable.total == 1)
    }

    @Test func claudeAlwaysHasTheSameThreeSlotsInPanelOrder() {
        let slots = QuotaSlots.slots(provider: "claude", accounts: [claude("a", session: nil, fable: nil)])
        #expect(slots.map(\.barID) == ["session_5h", "weekly_all", "weekly_fable"])
    }

    @Test func codexHasFiveHourAndWeeklyAndXaiOnlyWeekly() {
        #expect(QuotaSlots.slots(provider: "codex", accounts: []).map(\.barID) == ["session_5h", "weekly_all"])
        #expect(QuotaSlots.slots(provider: "xai", accounts: []).map(\.barID) == ["weekly_all"])
    }

    @Test func otherProvidersGetTheUnionOfReportedWindows() {
        let a = AccountSummary(id: "a", provider: "kimi", label: "a", state: .active, bars: [QuotaBar(id: "weekly_all", usedPercent: 10)])
        let b = AccountSummary(id: "b", provider: "kimi", label: "b", state: .active, bars: [QuotaBar(id: "daily", usedPercent: 10)])
        #expect(QuotaSlots.slots(provider: "kimi", accounts: [a, b]).map(\.barID) == ["daily", "weekly_all"])
    }

    @Test func legacyFableBarFillsTheFableSlot() {
        let account = AccountSummary(id: "a", provider: "claude", label: "a", state: .active, bars: [QuotaBar(id: "7d_oi", usedPercent: 25)])
        let slots = QuotaSlots.slots(provider: "claude", accounts: [account])
        #expect(slots.count == 3)
        let fable = QuotaSlots.reading(account, slot: slots[2], at: now)
        #expect(fable.remainingPercent == 75)
    }

    @Test func everyCardOfAProviderGetsEverySlotWithMissingOnesEmpty() {
        let accounts = [claude("full", fable: 10), claude("partial", fable: nil)]
        let slots = QuotaSlots.slots(provider: "claude", accounts: accounts)
        let partial = QuotaSlots.readings(accounts[1], slots: slots, at: now)
        #expect(partial.map(\.slot.barID) == ["session_5h", "weekly_all", "weekly_fable"])
        #expect(partial[2].remainingPercent == nil)
        #expect(partial[1].remainingPercent == 60)
        #expect(partial[1].resetsAt == now.addingTimeInterval(86_400))
    }

    @Test func anUnreportedFiveHourSlotReadsNoData() {
        let account = claude("idle", session: nil, weekly: 40)
        let reading = QuotaSlots.reading(account, slot: WindowSlot(barID: "session_5h"), at: now)
        #expect(reading.remainingPercent == nil)
        #expect(!reading.isReported)
        #expect(reading.resetsAt == nil)
        #expect(AccountOrder.routerReadings(account, now: now)?.short == nil)
    }

    @Test func windowThatAlreadyResetReadsFullWithoutAResetTime() {
        var account = claude("reset", weekly: 80)
        account.bars = [QuotaBar(id: "weekly_all", usedPercent: 80, resetsAt: now.addingTimeInterval(-60))]
        let reading = QuotaSlots.reading(account, slot: WindowSlot(barID: "weekly_all"), at: now)
        #expect(reading.remainingPercent == 100)
        #expect(reading.resetsAt == nil)
    }

    @Test func anUnreportedFiveHourSlotStaysOutOfThePool() throws {
        let reported = AccountSummary(id: "a", provider: "codex", label: "a", state: .active, bars: [
            QuotaBar(id: "session_5h", usedPercent: 80, resetsAt: now.addingTimeInterval(3_600)),
            QuotaBar(id: "weekly_all", usedPercent: 10, resetsAt: now.addingTimeInterval(86_400))
        ])
        let weeklyOnly = AccountSummary(id: "b", provider: "codex", label: "b", state: .active, bars: [
            QuotaBar(id: "weekly_all", usedPercent: 50, resetsAt: now.addingTimeInterval(86_400))
        ])
        let result = QuotaSlots.pools(provider: "codex", accounts: [reported, weeklyOnly], at: now)
        let fiveHour = try #require(result.pools.first { $0.slot.window == .session5h })
        #expect(fiveHour.remainingPercent == 20)
        #expect(fiveHour.covered == 1)
        #expect(fiveHour.total == 2)
        #expect(QuotaSlots.reading(weeklyOnly, slot: fiveHour.slot, at: now).remainingPercent == nil)
    }

    @Test func aReportedIdleFiveHourCountsAsFullInThePool() throws {
        let idle = claude("idle", plan: "pro", session: nil, weekly: 40)
        var withBar = idle
        withBar.bars.append(QuotaBar(id: "session_5h", usedPercent: 0))
        let busy = claude("busy", plan: "pro", session: 100, weekly: 40)
        let result = QuotaSlots.pools(provider: "claude", accounts: [withBar, busy], at: now)
        let fiveHour = try #require(result.pools.first { $0.slot.window == .session5h })
        #expect(fiveHour.covered == 2)
        #expect(fiveHour.remainingPercent == 50)
        let reading = QuotaSlots.reading(withBar, slot: fiveHour.slot, at: now)
        #expect(reading.remainingPercent == 100)
        #expect(reading.resetsAt == nil)
    }

    @Test func monthlyWindowsFillTheWeeklySlotOfTheSameProviderAsThePanel() throws {
        let monthly = AccountSummary(id: "m", provider: "codex", label: "m", state: .active, bars: [
            QuotaBar(id: "session_5h", usedPercent: 0, resetsAt: now.addingTimeInterval(3_600)),
            QuotaBar(id: "window_43200m", usedPercent: 25, resetsAt: now.addingTimeInterval(20 * 86_400))
        ])
        let weekly = AccountSummary(id: "w", provider: "codex", label: "w", state: .active, bars: [
            QuotaBar(id: "session_5h", usedPercent: 0, resetsAt: now.addingTimeInterval(3_600)),
            QuotaBar(id: "weekly_all", usedPercent: 75, resetsAt: now.addingTimeInterval(86_400))
        ])
        let slots = QuotaSlots.slots(provider: "codex", accounts: [monthly, weekly])
        #expect(slots.map(\.barID) == ["session_5h", "weekly_all"])
        #expect(!slots[1].holdsOnlyMonthlyReadings)
        let result = QuotaSlots.pools(provider: "codex", accounts: [monthly, weekly], at: now)
        let long = try #require(result.pools.first { $0.slot.window == .weekly })
        #expect(long.remainingPercent == 50)
        #expect(long.covered == 2)
        let onlyMonthly = QuotaSlots.slots(provider: "codex", accounts: [monthly])
        #expect(onlyMonthly.map(\.barID) == ["session_5h", "weekly_all"])
        #expect(onlyMonthly[1].holdsOnlyMonthlyReadings)
        #expect(QuotaSlots.reading(monthly, slot: onlyMonthly[1], at: now).remainingPercent == 75)
    }

    @Test func savedPoolAccountsBecomeUnweightedSummaries() throws {
        let saved = [
            PoolAccount(provider: "claude", availability: .available, bars: [QuotaBar(id: "weekly_all", usedPercent: 20)], credentialID: "a"),
            PoolAccount(provider: "claude", availability: .blocked(until: now.addingTimeInterval(600)), bars: [QuotaBar(id: "weekly_all", usedPercent: 60)])
        ]
        let accounts = AccountSummary.saved(saved)
        #expect(accounts.map(\.id) == ["a", "saved-1"])
        #expect(accounts[1].state == .cooldown)
        let result = QuotaSlots.pools(provider: "claude", accounts: accounts, at: now)
        #expect(!result.weighted)
        let weekly = try #require(result.pools.first { $0.slot.window == .weekly })
        #expect(weekly.remainingPercent == 60)
    }

    @Test func aFailedProviderCheckNeedsAttentionWithoutBlockingTheAccount() {
        var account = claude("checked")
        var state = ActiveRefreshState()
        state.recordFailure(.upstream(status: 503))
        account.providerCheckState = state
        #expect(account.needsAttention)
        #expect(account.block(at: now) == nil)
        #expect(AccountsStatus([account, claude("fine")]).needAttention == 1)
    }

    @Test func pageStatusCountsLoadedAndAttention() {
        let status = AccountsStatus([
            claude("ok"),
            claude("empty", session: nil, weekly: nil),
            claude("sign-in", state: .error, requiresSignIn: true),
            claude("off", state: .disabled)
        ])
        #expect(status.accounts == 4)
        #expect(status.loaded == 3)
        #expect(status.needAttention == 1)
    }
}
