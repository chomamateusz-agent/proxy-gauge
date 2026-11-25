import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Quota windows timeline")
struct QuotaTimelineTests {
    let now = date("2026-11-17T18:48:30Z")

    @Test func modelScopedWindowsAreNamedByTheirModel() {
        #expect(QuotaWindow(barID: "weekly_fable") == .weeklyFable)
        #expect(QuotaWindow(barID: "7d_oi") == .weeklyFable)
        #expect(QuotaWindow(barID: "weekly_opus_max") == .weeklyModel("opus_max"))
        #expect(QuotaWindow(barID: "weekly_opus_max").modelDisplayName == "Opus Max")
        #expect(QuotaWindow(barID: "weekly_all") == .weekly)
        #expect(!QuotaWindow.weeklyFable.limitsWholeAccount)
        #expect(QuotaWindow.weekly.limitsWholeAccount)
    }

    @Test func weeklyLanesRunFromWindowStartToResetWithTheNextWindowAfter() throws {
        let reset = date("2026-11-20T11:00:00Z")
        let bars = [
            QuotaBar(id: "session_5h", usedPercent: 0),
            QuotaBar(id: "weekly_all", usedPercent: 100, status: "rejected", resetsAt: reset),
            QuotaBar(id: "weekly_fable", usedPercent: 42, resetsAt: reset)
        ]
        let lanes = TimelineLane.lanes(bars: bars, provider: "claude", scale: .weekly, now: now)
        #expect(lanes.map(\.barID) == ["weekly_all", "weekly_fable"])
        let weekly = try #require(lanes.first)
        #expect(weekly.remainingPercent == 0)
        #expect(weekly.current == DateInterval(start: reset.addingTimeInterval(-7 * 86_400), end: reset))
        #expect(weekly.next == DateInterval(start: reset, duration: 7 * 86_400))
        #expect(lanes.last?.remainingPercent == 58)
    }

    @Test func idleFiveHourWindowStartsOnUseWithoutAnInterval() throws {
        let lanes = TimelineLane.lanes(bars: [QuotaBar(id: "session_5h", usedPercent: 0)], provider: "claude", scale: .fiveHour, now: now)
        let lane = try #require(lanes.first)
        #expect(lane.startsOnUse)
        #expect(lane.current == nil)
        #expect(lane.remainingPercent == 100)
    }

    @Test func passedResetIsItsOwnState() throws {
        let bar = QuotaBar(id: "session_5h", usedPercent: 100, status: "rejected", resetsAt: now.addingTimeInterval(-60))
        let lane = try #require(TimelineLane.lanes(bars: [bar], provider: "claude", scale: .fiveHour, now: now).first)
        #expect(lane.resetPassed)
        #expect(!lane.startsOnUse)
        #expect(lane.current == nil)
        #expect(lane.remainingPercent == 100)
    }

    @Test func accountBlockIncludesAWindowAtItsLimitWithoutACooldown() {
        let reset = now.addingTimeInterval(3_600)
        let account = AccountSummary(id: "a", provider: "claude", label: "a", state: .active, bars: [
            QuotaBar(id: "session_5h", usedPercent: 100, status: "rejected", resetsAt: reset),
            QuotaBar(id: "weekly_all", usedPercent: 20, resetsAt: now.addingTimeInterval(86_400))
        ])
        #expect(account.blockedUntil == nil)
        #expect(account.block(at: now) == PoolAccount.Block(until: reset, reason: .windowAtLimit("session_5h")))
        #expect(account.block(at: reset) == nil)
        let disabled = AccountSummary(id: "d", provider: "claude", label: "d", state: .disabled, bars: account.bars)
        #expect(disabled.block(at: now) == nil)
    }

    @Test func idleWindowOfABlockedAccountStartsWhenTheBlockEnds() throws {
        let lane = try #require(TimelineLane.lanes(bars: [QuotaBar(id: "session_5h", usedPercent: 0)], provider: "claude", scale: .fiveHour, now: now).first)
        let unblock = now.addingTimeInterval(2 * 86_400)
        #expect(lane.windowStartingAfter(nil, now: now) == DateInterval(start: now, duration: 5 * 3_600))
        #expect(lane.windowStartingAfter(PoolAccount.Block(until: unblock, reason: .windowAtLimit("weekly_all")), now: now) == DateInterval(start: unblock, duration: 5 * 3_600))
        #expect(lane.windowStartingAfter(PoolAccount.Block(until: nil, reason: .cooldown), now: now) == nil)

        let passed = QuotaBar(id: "session_5h", usedPercent: 100, status: "rejected", resetsAt: now.addingTimeInterval(-60))
        let passedLane = try #require(TimelineLane.lanes(bars: [passed], provider: "claude", scale: .fiveHour, now: now).first)
        #expect(passedLane.windowStartingAfter(PoolAccount.Block(until: unblock, reason: .cooldown), now: now)?.start == unblock)

        let running = QuotaBar(id: "session_5h", usedPercent: 30, resetsAt: now.addingTimeInterval(3_600))
        let runningLane = try #require(TimelineLane.lanes(bars: [running], provider: "claude", scale: .fiveHour, now: now).first)
        #expect(runningLane.windowStartingAfter(nil, now: now) == nil)
    }


    @Test func rangesCoverTwoWeeksOrADay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let weekly = TimelineScale.weekly.range(around: now, calendar: calendar)
        #expect(weekly.start == date("2026-11-15T00:00:00Z"))
        #expect(weekly.duration == 14 * 86_400)
        #expect(TimelineScale.weekly.ticks(in: weekly, calendar: calendar).count == 14)
        let hours = TimelineScale.fiveHour.range(around: now, calendar: calendar)
        #expect(hours.start == date("2026-11-17T12:00:00Z"))
        #expect(TimelineScale.fiveHour.ticks(in: hours, calendar: calendar).count == 8)
    }
}
