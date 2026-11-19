import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Overview layouts: per-account cells, headline window and comeback line")
struct ProviderOverviewTests {
    let coolingNow = date("2026-11-17T18:48:30Z")
    let fridayUnblock = date("2026-11-20T11:00:02Z")
    let saturdayUnblock = date("2026-11-21T13:07:24Z")
    let demoNow = Date(timeIntervalSince1970: 1_794_000_000)

    func coolingLimits() throws -> FleetLimits {
        try JSONDecoder.wire().decode(FleetLimits.self, from: Fixture.data("fleet-limits-cooling-pool.json"))
    }

    func coolingClientKey() throws -> [ProviderOverview] {
        let limits = try coolingLimits()
        let pools = HeadroomSnapshot.clientKey(.demo(authMode: .clientKey), limits: limits, now: coolingNow).pools(at: coolingNow)
        let accounts = limits.credentials.map { AccountSummary(fleet: $0, now: coolingNow) }
        return ProviderOverview.all(pools: pools, accounts: accounts, now: coolingNow)
    }

    func coolingManagement() throws -> [ProviderOverview] {
        let credentials = try coolingLimits().credentials.map(ManagementEquivalent.credential)
        let pools = HeadroomSnapshot.management(.demo(), credentials: credentials, now: coolingNow).pools(at: coolingNow)
        let accounts = credentials.map { AccountSummary(credential: $0, now: coolingNow) }
        return ProviderOverview.all(pools: pools, accounts: accounts, now: coolingNow)
    }

    func demo() async throws -> [ProviderOverview] {
        let now = demoNow
        let client = ManagementClient(baseURL: ServerProfile.demo().baseURL, managementKey: DemoTransport.secret, transport: DemoTransport(clock: { now }))
        let credentials = try await client.credentials().value.files
        let pools = HeadroomSnapshot.management(.demo(), credentials: credentials, now: now).pools(at: now)
        let accounts = credentials.map { AccountSummary(credential: $0, now: now) }
        return ProviderOverview.all(pools: pools, accounts: accounts, now: now)
    }

    func provider(_ name: String, in overviews: [ProviderOverview]) throws -> ProviderOverview {
        try #require(overviews.first { $0.pool.provider == name })
    }

    func remaining(_ overview: ProviderOverview, _ barID: String) -> [Double?] {
        overview.columns.map { $0.cell(barID).remainingPercent }
    }

    func usable(_ cell: AccountCell) -> Double? {
        cell.remainingPercent.map { cell.isBlocked ? 0 : $0 }
    }

    @Test func layoutSettingDefaultsToCompactRows() {
        #expect(OverviewLayout.resolve(nil) == .compactRows)
        #expect(OverviewLayout.resolve("answerFirst") == .answerFirst)
        #expect(OverviewLayout.resolve("accountsStrip") == .accountsStrip)
        #expect(OverviewLayout.resolve("tiles") == .compactRows)
        #expect(OverviewLayout.storageKey == "proxygauge.overview-layout.v1")
    }

    @Test func coolingPoolClaudeKeepsThePanelNumbers() throws {
        let claude = try provider("claude", in: try coolingClientKey())
        #expect(claude.pool.totalAccounts == 4)
        #expect(claude.pool.usableAccounts == 1)
        #expect(claude.stateCounts == [StateCount(state: .active, count: 1), StateCount(state: .cooldown, count: 2), StateCount(state: .disabled, count: 1)])

        let session = try #require(claude.pool.window(.session5h))
        #expect(session.remainingPercent == 200)
        #expect(session.capacityPercent == 200)
        #expect(session.usablePercent == 100)
        #expect(session.blockedPercent == 100)
        #expect(session.blockedUntil == fridayUnblock)
        #expect(session.accountSlots == 2)

        let weekly = try #require(claude.pool.window(.weekly))
        #expect(weekly.remainingPercent == 36)
        #expect(weekly.capacityPercent == 300)
        #expect(weekly.accountSlots == 3)

        let fable = try #require(claude.pool.window(.weeklyFable))
        #expect(fable.remainingPercent == 168)
        #expect(fable.usablePercent == 66)
        #expect(fable.blockedPercent == 102)
        #expect(fable.blockedPercentClearingFirst == 58)
        #expect(fable.blockedUntil == fridayUnblock)
    }

    @Test func coolingPoolClaudeColumnsAddUpToThePool() throws {
        let claude = try provider("claude", in: try coolingClientKey())
        #expect(claude.columns.map(\.label) == ["claude-aaaa0001", "claude-aaaa0002", "claude-aaaa0003", "claude-aaaa0004"])
        #expect(claude.columns.map(\.status) == [.usable, .disabled, .blocked(until: fridayUnblock), .blocked(until: date("2026-11-22T16:00:10Z"))])
        #expect(remaining(claude, "session_5h") == [100, nil, 100, nil])
        #expect(remaining(claude, "weekly_all") == [36, nil, 0, 0])
        #expect(remaining(claude, "weekly_fable") == [66, nil, 58, 44])
        #expect(claude.columns[0].cell("session_5h").value == .idleCountedAsFull)
        #expect(claude.columns[3].cell("session_5h").value == .leftOutWithoutRunningWindow)
        #expect(claude.columns[2].cell("weekly_fable").isBlocked)
        #expect(usable(claude.columns[2].cell("weekly_fable")) == 0)
        #expect(!claude.columns[0].cell("weekly_fable").isBlocked)
        for window in claude.pool.windows {
            #expect(claude.total(window.barID) == window.remainingPercent)
            #expect(claude.columns.compactMap { usable($0.cell(window.barID)) }.reduce(0, +) == window.usablePercent)
        }
    }

    @Test func coolingPoolHeadlineIsTheTightestGeneralWindow() throws {
        let overviews = try coolingClientKey()
        let claude = try provider("claude", in: overviews)
        #expect(claude.headline?.window == .weekly)
        #expect(claude.headline?.usablePercent == 36)
        #expect(claude.headline?.capacityPercent == 300)
        let second = try provider("codex", in: overviews)
        #expect(second.headline?.window == .weekly)
        #expect(second.headline?.usablePercent == 0)
        #expect(second.headline?.capacityPercent == 100)
    }

    @Test func coolingPoolComebackNamesTheFirstAccountBack() throws {
        let overviews = try coolingClientKey()
        let claude = try provider("claude", in: overviews)
        let back = try #require(claude.comeback)
        #expect(back.kind == .accountsBack)
        #expect(back.at == fridayUnblock)
        #expect(back.accounts == ["claude-aaaa0003"])
        #expect(back.gains == [
            Comeback.Gain(barID: "session_5h", percent: 100),
            Comeback.Gain(barID: "weekly_all", percent: 100),
            Comeback.Gain(barID: "weekly_fable", percent: 100)
        ])
        #expect(claude.headlineComeback == Comeback(kind: .accountsBack, at: fridayUnblock, accounts: ["claude-aaaa0003"], gains: [Comeback.Gain(barID: "weekly_all", percent: 100)]))

        let second = try provider("codex", in: overviews)
        #expect(second.columns.map(\.status) == [.blocked(until: saturdayUnblock)])
        #expect(remaining(second, "weekly_all") == [0])
        #expect(second.comeback == Comeback(kind: .accountsBack, at: saturdayUnblock, accounts: ["codex-bbbb0001"], gains: [Comeback.Gain(barID: "weekly_all", percent: 100)]))
    }

    @Test func managementModeGivesTheSameColumnsAsClientKeyMode() throws {
        let management = try coolingManagement()
        let clientKey = try coolingClientKey()
        #expect(management.map(\.pool.provider) == clientKey.map(\.pool.provider))
        for (left, right) in zip(management, clientKey) {
            #expect(left.columns.map(\.status) == right.columns.map(\.status))
            for window in right.pool.windows {
                #expect(remaining(left, window.barID) == remaining(right, window.barID))
            }
            #expect(left.headline?.barID == right.headline?.barID)
            #expect(left.comeback == right.comeback)
        }
    }

    @Test func demoClaudeColumnsMatchTheMockup() async throws {
        let claude = try provider("claude", in: try await demo())
        #expect(claude.columns.map(\.label) == ["lab@example.com", "studio@example.com", "team@example.com"])
        #expect(claude.columns.map(\.name) == ["lab", "studio", "team"])
        #expect(remaining(claude, "session_5h") == [88, 58, 0])
        #expect(remaining(claude, "weekly_all") == [66, 37, 12])
        #expect(remaining(claude, "weekly_fable") == [nil, 82, 60])
        #expect(claude.accountsWithoutData(in: "weekly_fable") == ["lab"])
        #expect(claude.stateCounts == [StateCount(state: .active, count: 2), StateCount(state: .cooldown, count: 1)])
        #expect(claude.total("session_5h") == 146)
        #expect(claude.total("weekly_all") == 115)
        #expect(claude.total("weekly_fable") == 142)
        #expect(claude.pool.window(.weekly)?.usablePercent == 103)
        #expect(claude.pool.window(.session5h)?.accountSlots == 3)
        #expect(claude.headline?.window == .weekly)
    }

    @Test func demoComebackLineNamesTeam() async throws {
        let overviews = try await demo()
        let claude = try provider("claude", in: overviews)
        let teamBack = demoNow.addingTimeInterval(47 * 60)
        #expect(claude.comeback == Comeback(kind: .accountsBack, at: teamBack, accounts: ["team"], gains: [
            Comeback.Gain(barID: "session_5h", percent: 100),
            Comeback.Gain(barID: "weekly_all", percent: 12),
            Comeback.Gain(barID: "weekly_fable", percent: 60)
        ]))
        #expect(claude.headlineComeback == Comeback(kind: .accountsBack, at: teamBack, accounts: ["team"], gains: [Comeback.Gain(barID: "weekly_all", percent: 12)]))

        let second = try provider("codex", in: overviews)
        #expect(second.columns.map(\.status) == [.disabled, .usable])
        #expect(remaining(second, "session_5h") == [nil, 62])
        #expect(second.headline?.window == .weekly)
        #expect(second.comeback == Comeback(kind: .windowsReset, at: demoNow.addingTimeInterval(90 * 60), accounts: ["codex"], gains: [Comeback.Gain(barID: "session_5h", percent: 38)]))
        #expect(second.headlineComeback == Comeback(kind: .windowsReset, at: demoNow.addingTimeInterval(75 * 3_600), accounts: ["codex"], gains: [Comeback.Gain(barID: "weekly_all", percent: 71)]))
    }

    @Test func demoProvidersWithoutDataSayWhy() async throws {
        let overviews = try await demo()
        let gemini = try provider("gemini-cli", in: overviews)
        #expect(!gemini.hasAccountColumns)
        #expect(gemini.stateCounts == [StateCount(state: .error, count: 1)])
        #expect(gemini.accountsNeedingSignIn == ["sandbox-demo-0193"])
        #expect(gemini.comeback == Comeback(kind: .needsSignIn, at: nil, accounts: ["sandbox-demo-0193"], gains: []))
        let xai = try provider("xai", in: overviews)
        #expect(!xai.hasAccountColumns)
        #expect(xai.headline == nil)
        #expect(xai.comeback == nil)
    }

    @Test func accountsClearingWithinAMinuteShareOneComeback() {
        let now = date("2026-11-17T12:00:00Z")
        let first = now.addingTimeInterval(3_600)
        let weeklyReset = now.addingTimeInterval(86_400)
        let accounts = [
            AccountSummary(id: "a", provider: "claude", label: "A", state: .cooldown, bars: [QuotaBar(id: "weekly_all", usedPercent: 70, resetsAt: weeklyReset)], blockedUntil: first),
            AccountSummary(id: "b", provider: "claude", label: "B", state: .cooldown, bars: [QuotaBar(id: "weekly_all", usedPercent: 40, resetsAt: weeklyReset)], blockedUntil: first.addingTimeInterval(30)),
            AccountSummary(id: "c", provider: "claude", label: "C", state: .cooldown, bars: [QuotaBar(id: "weekly_all", usedPercent: 10, resetsAt: weeklyReset)], blockedUntil: first.addingTimeInterval(600))
        ]
        let pools = PooledCapacity.pools(accounts.map(\.poolAccount), now: now)
        let overview = ProviderOverview(pool: pools[0], accounts: accounts, now: now)
        #expect(ProviderOverview.shortNames([
            AccountSummary(id: "x", provider: "claude", label: "team@one.example", state: .active, bars: []),
            AccountSummary(id: "y", provider: "claude", label: "team@two.example", state: .active, bars: []),
            AccountSummary(id: "z", provider: "claude", label: "lab@one.example", state: .active, bars: [])
        ]) == ["x": "team@one.example", "y": "team@two.example", "z": "lab"])
        #expect(overview.comeback == Comeback(kind: .accountsBack, at: first.addingTimeInterval(30), accounts: ["A", "B"], gains: [Comeback.Gain(barID: "weekly_all", percent: 90)]))
        #expect(overview.pool.window(.weekly)?.blockedPercentClearingFirst == 90)
    }

    @Test func aWindowResetBesideAComebackIsNotCalledAComeback() {
        let now = date("2026-11-17T12:00:00Z")
        let back = now.addingTimeInterval(3_600)
        let accounts = [
            AccountSummary(id: "a", provider: "claude", label: "A", state: .cooldown, bars: [QuotaBar(id: "weekly_all", usedPercent: 70, resetsAt: now.addingTimeInterval(86_400))], blockedUntil: back),
            AccountSummary(id: "b", provider: "claude", label: "B", state: .active, bars: [QuotaBar(id: "weekly_all", usedPercent: 80, resetsAt: back.addingTimeInterval(30))])
        ]
        let pools = PooledCapacity.pools(accounts.map(\.poolAccount), now: now)
        let overview = ProviderOverview(pool: pools[0], accounts: accounts, now: now)
        #expect(overview.comeback == Comeback(kind: .accountsBack, at: back.addingTimeInterval(30), accounts: ["A"], gains: [Comeback.Gain(barID: "weekly_all", percent: 30)]))
        #expect(overview.headlineComeback == overview.comeback)
    }

    @Test func anAccountReportingAnErrorIsNotShownAsActive() {
        let now = date("2026-11-17T12:00:00Z")
        let accounts = [
            AccountSummary(id: "a", provider: "claude", label: "A", state: .active, bars: [QuotaBar(id: "weekly_all", usedPercent: 50, resetsAt: nil)]),
            AccountSummary(id: "b", provider: "claude", label: "B", state: .error, bars: [QuotaBar(id: "weekly_all", usedPercent: 20, resetsAt: nil)])
        ]
        let pools = PooledCapacity.pools(accounts.map(\.poolAccount), now: now)
        let overview = ProviderOverview(pool: pools[0], accounts: accounts, now: now)
        #expect(overview.columns.map(\.status) == [.usable, .reportsError])
        #expect(!overview.columns[1].isBlocked)
        #expect(overview.total("weekly_all") == overview.pool.window(.weekly)?.remainingPercent)
    }

    @Test func roundedCellsAddUpToTheRoundedTotal() {
        let now = date("2026-11-17T12:00:00Z")
        let accounts = [("a", 62.5), ("b", 37.5)].map { id, remaining in
            AccountSummary(id: id, provider: "claude", label: id, state: .active, bars: [QuotaBar(id: "weekly_all", usedPercent: 100 - remaining, resetsAt: nil)])
        }
        let pools = PooledCapacity.pools(accounts.map(\.poolAccount), now: now)
        let overview = ProviderOverview(pool: pools[0], accounts: accounts, now: now)
        let cells = overview.roundedCells("weekly_all")
        #expect(overview.total("weekly_all") == 100)
        #expect(cells.values.reduce(0, +) == 100)
        #expect(cells == ["a": 63, "b": 37])
    }
}
