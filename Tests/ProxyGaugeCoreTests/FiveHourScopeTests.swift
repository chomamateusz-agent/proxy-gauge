import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Five-hour rules stay with the providers that report the window")
struct FiveHourScopeTests {
    let now = date("2026-11-14T10:00:00Z")

    @Test func otherProvidersWithoutAFiveHourBarStayInThePool() throws {
        let reporting = PoolAccount(provider: "kimi", availability: .available, bars: [
            QuotaBar(id: "session_5h", usedPercent: 40, resetsAt: date("2026-11-14T12:00:00Z")),
            QuotaBar(id: "weekly_all", usedPercent: 10)
        ])
        let weeklyOnly = PoolAccount(provider: "kimi", availability: .available, bars: [QuotaBar(id: "weekly_all", usedPercent: 20)])
        let pool = try #require(PooledCapacity.pools([reporting, weeklyOnly], now: now).first)
        let session = try #require(pool.window(.session5h))
        #expect(session.accountsLeftOut == 0)
        #expect(session.accounts == 2)
        #expect(session.unknownAccounts == 1)
    }

    @Test func usableClaudeAccountWithoutAFiveHourBarCountsAsFull() throws {
        let reporting = PoolAccount(provider: "claude", availability: .available, bars: [QuotaBar(id: "session_5h", usedPercent: 40), QuotaBar(id: "weekly_all", usedPercent: 10)])
        let weeklyOnly = PoolAccount(provider: "claude", availability: .available, bars: [QuotaBar(id: "weekly_all", usedPercent: 20)])
        let session = try #require(PooledCapacity.pools([reporting, weeklyOnly], now: now).first?.window(.session5h))
        #expect(session.accountsCountedAsFull == 1)
        #expect(session.accountsLeftOut == 0)
        #expect(session.accounts == 2)
        #expect(session.remainingPercent == 160)
    }

    @Test func startsOnUseIsOnlyForTheProvidersWithAFiveHourWindow() {
        let idleSession = QuotaBar(id: "session_5h", usedPercent: 0)
        let fullDaily = QuotaBar(id: "daily", usedPercent: 0)
        for provider in ["claude", "codex"] {
            #expect(idleSession.startsOnUse(provider: provider, at: now))
        }
        #expect(!idleSession.startsOnUse(provider: "kimi", at: now))
        #expect(!fullDaily.startsOnUse(provider: "devin", at: now))
        #expect(!fullDaily.startsOnUse(provider: "claude", at: now))
    }
}
