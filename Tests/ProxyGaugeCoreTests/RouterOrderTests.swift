import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Router order mirrors the fork's use-or-lose selector")
struct RouterOrderTests {
    let now = date("2026-11-21T10:00:00Z")
    let useOrLose = RouterSettings(strategy: "use-or-lose")

    func reading(weekly: Double?, weeklyReset: Date?, short: Double? = nil, shortReset: Date? = nil, credits: Bool = false, observedAt: Date? = nil) -> RouterReadings {
        RouterReadings(
            weekly: RouterWindow(usedPercent: weekly, resetsAt: weeklyReset),
            short: short.map { RouterWindow(usedPercent: $0, resetsAt: shortReset ?? now.addingTimeInterval(3_600)) },
            creditsAvailable: credits,
            observedAt: observedAt ?? now.addingTimeInterval(-60)
        )
    }

    func candidate(_ name: String, provider: String = "claude", priority: Int = 0, endsAt: Date? = nil, _ readings: RouterReadings?, out: RouterOutOfRotation? = nil) -> RouterCandidate<String> {
        RouterCandidate(item: name, provider: provider, priority: priority, endsAt: endsAt, readings: readings, outOfRotation: out)
    }

    func names(_ ranked: [RankedCandidate<String>]) -> [String] {
        ranked.map(\.candidate.item)
    }

    func days(_ value: Double) -> Date { now.addingTimeInterval(value * 86_400) }

    @Test func settingsFallBackToTheProxyDefaults() {
        #expect(RouterSettings(strategy: nil).strategy == "round-robin")
        #expect(RouterSettings(strategy: " Use-Or-Lose ").ranksByUseOrLose)
        #expect(RouterSettings(strategy: "ff").strategy == "fill-first")
        #expect(RouterSettings(strategy: "something-new").strategy == "round-robin")
        #expect(RouterSettings(strategy: "use-or-lose").shortWindowCapPercent == 95)
        #expect(RouterSettings(strategy: "use-or-lose", shortWindowCapPercent: 1).shortWindowCapPercent == 95)
        #expect(RouterSettings(strategy: "use-or-lose", shortWindowCapPercent: 120).shortWindowCapPercent == 95)
        #expect(RouterSettings(strategy: "use-or-lose", shortWindowCapPercent: 80).shortWindowCapPercent == 80)
        #expect(RouterSettings(strategy: "use-or-lose").drainEndingCredentials)
        #expect(!RouterSettings(strategy: "use-or-lose", drainEndingCredentials: false).drainEndingCredentials)
    }

    @Test func theAccountWhoseWeekEndsSoonestGoesFirst() {
        let ranked = RouterOrder.rankProvider([
            candidate("late", reading(weekly: 10, weeklyReset: days(6))),
            candidate("soon", reading(weekly: 60, weeklyReset: days(1))),
            candidate("middle", reading(weekly: 20, weeklyReset: days(3)))
        ], settings: useOrLose, now: now)
        #expect(names(ranked) == ["soon", "middle", "late"])
        #expect(ranked.first?.placement == .ranked(position: 1, tier: .room, sampled: true, sampledProvider: true))
    }

    @Test func resetsWithinAnHourTieAndTheLeastUsedWins() {
        let ranked = RouterOrder.rankProvider([
            candidate("busy", reading(weekly: 70, weeklyReset: days(1))),
            candidate("quiet", reading(weekly: 30, weeklyReset: days(1).addingTimeInterval(50 * 60))),
            candidate("outside", reading(weekly: 5, weeklyReset: days(1).addingTimeInterval(61 * 60)))
        ], settings: useOrLose, now: now)
        #expect(names(ranked) == ["quiet", "busy", "outside"])
    }

    @Test func equalUseInTheTieGroupPicksTheEarlierReset() {
        let ranked = RouterOrder.rankProvider([
            candidate("later", reading(weekly: 40, weeklyReset: days(1).addingTimeInterval(30 * 60))),
            candidate("earlier", reading(weekly: 40, weeklyReset: days(1)))
        ], settings: useOrLose, now: now)
        #expect(names(ranked) == ["earlier", "later"])
    }

    @Test func aFullFiveHourWindowDropsToTheCappedTier() {
        let ranked = RouterOrder.rankProvider([
            candidate("capped", reading(weekly: 10, weeklyReset: days(1), short: 96)),
            candidate("room", reading(weekly: 50, weeklyReset: days(5), short: 40))
        ], settings: useOrLose, now: now)
        #expect(names(ranked) == ["room", "capped"])
        #expect(ranked[1].placement == .ranked(position: 2, tier: .capped, sampled: true, sampledProvider: true))
        #expect(AccountOrder.badge(ranked[1].placement) == .shortWindowCap)
    }

    @Test func theCapFollowsTheConfiguredPercentAndCreditsLiftIt() {
        let lowCap = RouterSettings(strategy: "use-or-lose", shortWindowCapPercent: 80)
        let ranked = RouterOrder.rankProvider([
            candidate("eighty-five", reading(weekly: 10, weeklyReset: days(1), short: 85)),
            candidate("other", reading(weekly: 50, weeklyReset: days(5), short: 10))
        ], settings: lowCap, now: now)
        #expect(names(ranked) == ["other", "eighty-five"])
        let withCredits = RouterOrder.rankProvider([
            candidate("credits", provider: "codex", reading(weekly: 10, weeklyReset: days(1), short: 99, credits: true)),
            candidate("other", provider: "codex", reading(weekly: 50, weeklyReset: days(5), short: 10))
        ], settings: useOrLose, now: now)
        #expect(names(withCredits) == ["credits", "other"])
    }

    @Test func anExpiredFiveHourWindowDoesNotCap() {
        let ranked = RouterOrder.rankProvider([
            candidate("expired", reading(weekly: 10, weeklyReset: days(1), short: 100, shortReset: now.addingTimeInterval(-60))),
            candidate("other", reading(weekly: 50, weeklyReset: days(5), short: 10))
        ], settings: useOrLose, now: now)
        #expect(names(ranked) == ["expired", "other"])
    }

    @Test func aWeekAtItsLimitGoesLast() {
        let ranked = RouterOrder.rankProvider([
            candidate("limited", reading(weekly: 100, weeklyReset: days(1))),
            candidate("capped", reading(weekly: 10, weeklyReset: days(2), short: 99)),
            candidate("room", reading(weekly: 90, weeklyReset: days(6)))
        ], settings: useOrLose, now: now)
        #expect(names(ranked) == ["room", "capped", "limited"])
        #expect(ranked[2].placement == .ranked(position: 3, tier: .limited, sampled: true, sampledProvider: true))
    }

    @Test func higherPriorityWinsBeforeResetTimes() {
        let ranked = RouterOrder.rankProvider([
            candidate("soon", reading(weekly: 10, weeklyReset: days(1))),
            candidate("preferred", priority: 5, reading(weekly: 80, weeklyReset: days(6)))
        ], settings: useOrLose, now: now)
        #expect(names(ranked) == ["preferred", "soon"])
    }

    @Test func endingCredentialsDrainFirstUnlessTurnedOff() {
        let accounts = [
            candidate("weekly-soon", reading(weekly: 10, weeklyReset: days(2))),
            candidate("ending", endsAt: days(1), reading(weekly: 10, weeklyReset: days(6)))
        ]
        #expect(names(RouterOrder.rankProvider(accounts, settings: useOrLose, now: now)) == ["ending", "weekly-soon"])
        let keep = RouterSettings(strategy: "use-or-lose", drainEndingCredentials: false)
        #expect(names(RouterOrder.rankProvider(accounts, settings: keep, now: now)) == ["weekly-soon", "ending"])
    }

    @Test func coolingDisabledAndEndedLeaveTheRotationInThatOrder() {
        let ranked = RouterOrder.rankProvider([
            candidate("ended", reading(weekly: 10, weeklyReset: days(1)), out: .ended),
            candidate("disabled", reading(weekly: 10, weeklyReset: days(1)), out: .disabled),
            candidate("active", reading(weekly: 50, weeklyReset: days(4))),
            candidate("cooling", reading(weekly: 10, weeklyReset: days(1)), out: .cooling)
        ], settings: useOrLose, now: now)
        #expect(names(ranked) == ["active", "cooling", "disabled", "ended"])
        #expect(ranked.dropFirst().map { AccountOrder.badge($0.placement) } == [.coolingDown, .disabled, .ended])
    }

    @Test func unsampledAccountsRankAfterSampledOnesAndSayNoReading() {
        let ranked = RouterOrder.rankProvider([
            candidate("never", nil),
            candidate("stale", reading(weekly: 10, weeklyReset: days(1), observedAt: now.addingTimeInterval(-8 * 86_400))),
            candidate("sampled", reading(weekly: 90, weeklyReset: days(6)))
        ], settings: useOrLose, now: now)
        #expect(names(ranked).first == "sampled")
        #expect(ranked.dropFirst().allSatisfy { AccountOrder.badge($0.placement) == .noReading })
        #expect(AccountOrder.badge(ranked[0].placement) == .next)
    }

    @Test func anIdleWeekWithoutResetCountsOnlyWhileTheSampleIsFresh() {
        let fresh = RouterOrder.windowUsable(RouterWindow(usedPercent: 0, resetsAt: nil), observedAt: now.addingTimeInterval(-5 * 60), now: now)
        let old = RouterOrder.windowUsable(RouterWindow(usedPercent: 0, resetsAt: nil), observedAt: now.addingTimeInterval(-20 * 60), now: now)
        #expect(fresh)
        #expect(!old)
    }

    @Test func providersAreRankedSeparatelyInTheirFirstSeenOrder() {
        let ranked = RouterOrder.rank([
            candidate("codex-late", provider: "codex", reading(weekly: 10, weeklyReset: days(6))),
            candidate("claude-a", reading(weekly: 10, weeklyReset: days(5))),
            candidate("codex-soon", provider: "codex", reading(weekly: 10, weeklyReset: days(1))),
            candidate("claude-b", reading(weekly: 10, weeklyReset: days(2)))
        ], settings: useOrLose, now: now)
        #expect(names(ranked) == ["codex-soon", "codex-late", "claude-b", "claude-a"])
        let positions = ranked.compactMap { ranked -> Int? in
            if case .ranked(let position, _, _, _) = ranked.placement { return position }
            return nil
        }
        #expect(positions == [1, 2, 1, 2])
    }

    @Test func otherProvidersKeepListOrderWithoutTheNoReadingBadge() {
        let ranked = RouterOrder.rankProvider([
            candidate("x1", provider: "xai", nil),
            candidate("x2", provider: "xai", nil)
        ], settings: useOrLose, now: now)
        #expect(names(ranked) == ["x1", "x2"])
        #expect(ranked.map { AccountOrder.badge($0.placement) } == [.next, .position(2)])
    }
}
