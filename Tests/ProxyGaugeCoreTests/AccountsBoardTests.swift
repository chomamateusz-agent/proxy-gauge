import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Accounts board")
struct AccountsBoardTests {
    @Test func layoutDefaultsToCardsAndHidesTheTableOnCompactWidth() {
        #expect(AccountsLayout.resolve(nil, compactWidth: false) == .cards)
        #expect(AccountsLayout.resolve("unknown", compactWidth: false) == .cards)
        #expect(AccountsLayout.resolve("table", compactWidth: false) == .table)
        #expect(AccountsLayout.resolve("table", compactWidth: true) == .cards)
        #expect(AccountsLayout.resolve("list", compactWidth: true) == .list)
        #expect(AccountsLayout.available(compactWidth: true) == [.cards, .list])
        #expect(AccountsLayout.available(compactWidth: false) == [.cards, .list, .table, .timeline])
    }

    @Test func layoutChoicePersistsInTheDeviceDefaults() {
        let suite = "proxygauge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AccountsLayout.table.rawValue, forKey: AccountsLayout.storageKey)
        let reread = UserDefaults(suiteName: suite)!.string(forKey: AccountsLayout.storageKey)
        #expect(AccountsLayout.resolve(reread, compactWidth: false) == .table)
        #expect(AccountsLayout.resolve(reread, compactWidth: true) == .cards)
        #expect(UserDefaults(suiteName: suite)!.string(forKey: AccountsLayout.storageKey) == "table")
    }

    @Test func demoAccountsSummariseWithRemainingQuotaAndNoPlans() async throws {
        let now = Date()
        let client = ManagementClient(baseURL: ServerProfile.demoBaseURL, managementKey: DemoTransport.secret, transport: DemoTransport(clock: { now }))
        let accounts = AccountSummary.board(try await client.credentials().value.files.map { AccountSummary(credential: $0, now: now) })
        #expect((4...7).contains(accounts.count))
        #expect(Set(accounts.map(\.provider)).count >= 3)
        #expect(Set(accounts.map(\.state)) == Set(CredentialState.allCases))
        #expect(accounts.allSatisfy { $0.plan == nil })
        #expect(accounts.map(\.provider) == accounts.map(\.provider).sorted { ProviderCatalog.sortKey($0) < ProviderCatalog.sortKey($1) })

        let cooling = try #require(accounts.first { $0.state == .cooldown })
        #expect(cooling.blockedUntil.map { $0 > now } == true)
        #expect(cooling.bar("session_5h")?.isAtLimit(at: now) == true)
        let studio = try #require(accounts.first { $0.label == "studio@example.com" })
        #expect(studio.bar("session_5h")?.remainingPercent(at: now) == 58)
        #expect(AccountSummary.windowIDs(accounts) == ["session_5h", "weekly_all", "weekly_fable"])
    }

    @Test func passedResetCountsAsAFullWindowAndClearsTheLimit() {
        let now = Date(timeIntervalSince1970: 1_794_611_400)
        let bar = QuotaBar(id: "session_5h", usedPercent: 100, status: "rejected", resetsAt: now.addingTimeInterval(-60))
        #expect(bar.remainingPercent(at: now) == 100)
        #expect(!bar.isAtLimit(at: now))
        #expect(bar.remainingPercent(at: now.addingTimeInterval(-120)) == 0)
        #expect(bar.isAtLimit(at: now.addingTimeInterval(-120)))
        #expect(QuotaBar(id: "weekly_all", usedPercent: nil).remainingPercent(at: now) == nil)
    }

    @Test func fleetCredentialKeepsOnlyActiveCredentialWideCooldowns() throws {
        let now = Date(timeIntervalSince1970: 1_794_611_400)
        let json = """
        {"label":"claude-1","provider":"claude","plan":null,"state":"cooldown","bars":[{"id":"weekly_all","percent":40}],
         "cooldowns":[{"scope":"model","model":"claude-opus-5-5","reason":"quota","until":"2026-11-19T00:00:00Z"},
                      {"scope":"credential","reason":"quota","until":"2026-11-18T22:00:00Z"}],
         "credits":{"balance":3}}
        """
        let credential = try JSONDecoder.wire().decode(FleetCredential.self, from: Data(json.utf8))
        let summary = AccountSummary(fleet: credential, now: now)
        #expect(summary.state == .cooldown)
        #expect(summary.blockedUntil == WireDate.parse("2026-11-18T22:00:00Z"))
        #expect(summary.creditsBalance == 3)
        #expect(summary.bar("weekly_all")?.remainingPercent(at: now) == 60)
    }
}

@Suite("Automatic refresh loop")
@MainActor
struct AutoRefreshLoopTests {
    struct Stop: Error {}

    final class Counter {
        var refreshes = 0
        var sleeps: [TimeInterval] = []
    }

    func run(enabled: Bool, passes: Int = 3) async -> Counter {
        let counter = Counter()
        await AutoRefreshLoop.run(
            refreshesAutomatically: enabled,
            interval: 60,
            sleep: { interval in
                counter.sleeps.append(interval)
                if counter.sleeps.count >= passes { throw Stop() }
            },
            refresh: { counter.refreshes += 1 }
        )
        return counter
    }

    @Test func repeatsAtTheIntervalWhileAutomaticRefreshIsOn() async {
        let counter = await run(enabled: true)
        #expect(counter.refreshes == 3)
        #expect(counter.sleeps == [60, 60, 60])
    }

    @Test func offNeverRefreshesEvenAnEmptyScreen() async {
        let counter = await run(enabled: false)
        #expect(counter.refreshes == 0)
        #expect(counter.sleeps.isEmpty)
    }
}
