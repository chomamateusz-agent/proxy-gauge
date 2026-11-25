import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Quota presentation regressions")
struct QuotaPresentationRegressionTests {
    let now = date("2026-11-17T10:00:00Z")

    @Test(arguments: [
        ("2027-03-29T22:30:00Z", "2027-03-27T23:00:00Z", "2027-04-10T22:00:00Z", 23),
        ("2026-10-26T23:30:00Z", "2026-10-24T22:00:00Z", "2026-11-07T23:00:00Z", 25)
    ])
    func weeklyRangeUsesLocalDaysAcrossDST(_ instant: String, _ start: String, _ end: String, _ transitionHours: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Warsaw"))
        let range = TimelineScale.weekly.range(around: date(instant), calendar: calendar)
        #expect(range.start == date(start))
        #expect(range.end == date(end))
        let ticks = TimelineScale.weekly.ticks(in: range, calendar: calendar)
        #expect(ticks.count == 14)
        #expect(ticks.allSatisfy { calendar.component(.hour, from: $0) == 0 && calendar.component(.minute, from: $0) == 0 })
        let ends = Array(ticks.dropFirst()) + [range.end]
        for (tick, end) in zip(ticks, ends) {
            #expect(calendar.date(byAdding: .day, value: 1, to: tick) == end)
        }
        #expect(try #require(ends.first).timeIntervalSince(try #require(ticks.first)) == Double(transitionHours) * 3_600)
    }

    @Test func nextWindowWaitsForTheOtherWindowAndMatchesPoolBlocking() throws {
        let reset = now.addingTimeInterval(3_600)
        let unblock = now.addingTimeInterval(48 * 3_600)
        let bars = [
            QuotaBar(id: "session_5h", usedPercent: 50, resetsAt: reset),
            QuotaBar(id: "weekly_all", usedPercent: 100, status: "rejected", resetsAt: unblock)
        ]
        let account = AccountSummary(id: "a", provider: "claude", label: "a", state: .active, bars: bars)
        let lane = try #require(TimelineLane.lanes(bars: bars, provider: "claude", scale: .fiveHour, now: now).first)
        let next = try #require(lane.next)
        #expect(lane.nextWindow(after: nil) == next)
        #expect(lane.nextWindow(after: PoolAccount.Block(until: reset.addingTimeInterval(-60), reason: .cooldown)) == next)
        #expect(lane.nextWindow(after: PoolAccount.Block(until: reset, reason: .cooldown)) == next)
        #expect(lane.nextWindow(after: account.block(for: lane.barID, at: now)) == DateInterval(start: unblock, duration: 5 * 3_600))
        #expect(lane.nextWindow(after: PoolAccount.Block(until: nil, reason: .cooldown)) == nil)
        let pool = try #require(PooledCapacity.pools([account.poolAccount], now: now).first)
        #expect(pool.window(.session5h)?.blockedUntil == unblock)
        #expect(account.block(at: now) == account.block(for: lane.barID, at: now))
    }

    @Test func exhaustedLaneDoesNotBlockItsOwnNextWindow() throws {
        let reset = now.addingTimeInterval(3_600)
        let account = AccountSummary(id: "a", provider: "claude", label: "a", state: .active, bars: [
            QuotaBar(id: "session_5h", usedPercent: 100, status: "rejected", resetsAt: reset)
        ])
        let lane = try #require(TimelineLane.lanes(bars: account.bars, provider: "claude", scale: .fiveHour, now: now).first)
        #expect(account.block(at: now)?.until == reset)
        #expect(account.block(for: lane.barID, at: now) == nil)
        #expect(lane.nextWindow(after: account.block(for: lane.barID, at: now)) == lane.next)
    }

    @Test(arguments: [(-60.0, false), (0.0, false), (7.0, false), (60.0, false), (61.0, true), (3_000.0, true)])
    func blockReasonFollowsTheDominantConstraintWithJitterTolerance(_ offset: Double, _ cooldownWins: Bool) throws {
        let reset = now.addingTimeInterval(600)
        let cooldown = reset.addingTimeInterval(offset)
        let account = PoolAccount(provider: "claude", availability: .blocked(until: cooldown), bars: [
            QuotaBar(id: "weekly_all", usedPercent: 100, resetsAt: reset)
        ])
        let block = try #require(account.block(for: nil, at: now))
        #expect(block.until == max(reset, cooldown))
        #expect(block.reason == (cooldownWins ? .cooldown : .windowAtLimit("weekly_all")))
    }

    @Test func unknownEndsAndSignInChooseTheBindingReason() {
        let reset = now.addingTimeInterval(600)
        let exhausted = QuotaBar(id: "weekly_all", usedPercent: 100, resetsAt: reset)
        let openCooldown = PoolAccount(provider: "claude", availability: .blocked(until: nil), bars: [exhausted])
        #expect(openCooldown.block(for: nil, at: now) == PoolAccount.Block(until: nil, reason: .cooldown))
        var unknownWindow = openCooldown
        unknownWindow.bars.append(QuotaBar(id: "session_5h", usedPercent: 100))
        #expect(unknownWindow.block(for: nil, at: now) == PoolAccount.Block(until: nil, reason: .windowAtLimit("session_5h")))
        unknownWindow.availability = .blocked(until: reset.addingTimeInterval(3_600))
        #expect(unknownWindow.block(for: nil, at: now)?.reason == .windowAtLimit("session_5h"))
        unknownWindow.availability = .needsSignIn
        #expect(unknownWindow.block(for: nil, at: now) == PoolAccount.Block(until: nil, reason: .signIn))
    }

    @Test func latestExhaustedWindowDeterminesReason() {
        let reset = now.addingTimeInterval(600)
        let account = PoolAccount(provider: "claude", availability: .blocked(until: reset.addingTimeInterval(500)), bars: [
            QuotaBar(id: "weekly_all", usedPercent: 100, resetsAt: reset),
            QuotaBar(id: "session_5h", usedPercent: 100, resetsAt: reset.addingTimeInterval(600))
        ])
        #expect(account.block(for: nil, at: now)?.reason == .windowAtLimit("session_5h"))
    }

    @Test func weeklyOnlyAccountsAreLeftOutOfTheFiveHourPool() throws {
        let weekly = QuotaBar(id: "weekly_all", usedPercent: 20, resetsAt: now.addingTimeInterval(86_400))
        let unreported = PoolAccount(provider: "claude", availability: .available, bars: [weekly])
        let sampled = PoolAccount(provider: "claude", availability: .available, bars: [QuotaBar(id: "session_5h", usedPercent: 20)])
        let pool = try #require(PooledCapacity.pools([unreported, sampled], now: now).first)
        #expect(pool.window(.session5h)?.accountsLeftOut == 1)
        #expect(pool.window(.session5h)?.remainingPercent == 80)
        let unsampledPool = try #require(PooledCapacity.pools([unreported], now: now).first)
        #expect(unsampledPool.window(.session5h) == nil)
    }

    @Test func blockEndGroupsUseTheirLatestEndAndOneMinuteTolerance() throws {
        let reset = date("2026-11-20T11:00:00Z")
        func account(_ seconds: Double?, remaining: Double) -> PoolAccount {
            PoolAccount(provider: "claude", availability: .blocked(until: seconds.map { reset.addingTimeInterval($0) }), bars: [
                QuotaBar(id: "weekly_all", usedPercent: 100, resetsAt: reset),
                QuotaBar(id: "weekly_fable", usedPercent: 100 - remaining, resetsAt: reset.addingTimeInterval(86_400))
            ])
        }
        let together = [account(2, remaining: 58), account(7, remaining: 44)]
        let window = try #require(PooledCapacity.pools(together, now: now).first?.window(.weeklyFable))
        #expect(window.blockClearsAtOnce)
        #expect(window.blockedPercentClearingFirst == 102)
        #expect(window.blockedUntil == reset.addingTimeInterval(7))
        #expect(window.blockReason == .windowAtLimit("weekly_all"))
        let boundary = try #require(PooledCapacity.pools(together + [account(62, remaining: 20)], now: now).first?.window(.weeklyFable))
        #expect(boundary.blockClearsAtOnce)
        #expect(boundary.blockedPercentClearingFirst == 122)
        #expect(boundary.blockedUntil == reset.addingTimeInterval(62))
        for extra in [account(63, remaining: 20), account(nil, remaining: 20)] {
            let staggered = try #require(PooledCapacity.pools(together + [extra], now: now).first?.window(.weeklyFable))
            #expect(!staggered.blockClearsAtOnce)
            #expect(staggered.blockedPercentClearingFirst == 102)
            #expect(staggered.blockedUntil == reset.addingTimeInterval(7))
        }
        let indefinite = try #require(PooledCapacity.pools([account(nil, remaining: 58), account(nil, remaining: 44)], now: now).first?.window(.weeklyFable))
        #expect(indefinite.blockClearsAtOnce)
        #expect(indefinite.blockedUntil == nil)
        #expect(indefinite.blockedPercentClearingFirst == 102)
    }
}
