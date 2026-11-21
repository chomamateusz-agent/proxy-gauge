import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Effective remaining quota")
struct EffectiveRemainingTests {
    let now = date("2026-11-14T10:00:00Z")
    let future = date("2026-11-14T12:00:00Z")
    let past = date("2026-11-14T09:00:00Z")

    @Test func oneRuleDecidesWhatIsLeft() {
        #expect(QuotaBar(id: "session_5h", usedPercent: 100, status: "rejected", resetsAt: past).remainingPercent(at: now) == 100)
        #expect(QuotaBar(id: "session_5h", usedPercent: nil, resetsAt: past).remainingPercent(at: now) == 100)
        #expect(QuotaBar(id: "session_5h", usedPercent: 70, status: "rejected", resetsAt: future).remainingPercent(at: now) == 0)
        #expect(QuotaBar(id: "session_5h", usedPercent: nil, status: "rejected", resetsAt: future).remainingPercent(at: now) == 0)
        #expect(QuotaBar(id: "session_5h", usedPercent: 42, resetsAt: future).remainingPercent(at: now) == 58)
        #expect(QuotaBar(id: "session_5h", usedPercent: nil, status: "allowed", resetsAt: future).remainingPercent(at: now) == nil)
        #expect(QuotaBar(id: "session_5h", usedPercent: nil).remainingPercent(at: now) == nil)
    }

    @Test func effectiveUsageMirrorsTheRemainingRule() {
        #expect(QuotaBar(id: "weekly_all", usedPercent: nil, status: "rejected", resetsAt: future).effectiveUsedPercent(at: now) == 100)
        #expect(QuotaBar(id: "weekly_all", usedPercent: 30, resetsAt: past).effectiveUsedPercent(at: now) == 0)
        #expect(QuotaBar(id: "weekly_all", usedPercent: nil).effectiveUsedPercent(at: now) == nil)
    }

    @Test func rejectedWindowWithoutUtilisationLimitsTheBestAccount() {
        let account = PoolAccount(provider: "claude", availability: .available, bars: [
            QuotaBar(id: "session_5h", usedPercent: nil, status: "rejected", resetsAt: future),
            QuotaBar(id: "weekly_all", usedPercent: 20, resetsAt: future)
        ])
        let other = PoolAccount(provider: "claude", availability: .available, bars: [QuotaBar(id: "weekly_all", usedPercent: 70, resetsAt: future)])
        let headroom = HeadroomCalculator.fromPoolAccounts([account, other], now: now)
        #expect(headroom.first?.headroomPercent == 30)
        #expect(HeadroomCalculator.tightestWindow(account.bars, now: now)?.headroomPercent == 0)
        #expect(HeadroomCalculator.tightestWindow(account.bars, now: now)?.id == "session_5h")
    }

    @Test func barWithoutAnyUsageIsNotTreatedAsFull() {
        let unknownOnly = PoolAccount(provider: "claude", availability: .available, bars: [QuotaBar(id: "weekly_all", usedPercent: nil, status: "allowed", resetsAt: future)])
        #expect(HeadroomCalculator.fromPoolAccounts([unknownOnly], now: now).first?.headroomPercent == nil)
        #expect(PooledCapacity.pools([unknownOnly], now: now).first?.window(.weekly)?.unknownAccounts == 1)
    }

    @Test func fiveHourStatesAreToldApart() {
        let weekly = QuotaBar(id: "weekly_all", usedPercent: 10, resetsAt: future)
        #expect(FiveHourWindowState(provider: "claude", bars: [], now: now) == .neverSampled)
        #expect(FiveHourWindowState(provider: "claude", bars: [weekly], now: now) == .notReported)
        #expect(FiveHourWindowState(provider: "claude", bars: [weekly, QuotaBar(id: "session_5h", usedPercent: 0)], now: now) == .startsOnUse)
        #expect(FiveHourWindowState(provider: "claude", bars: [QuotaBar(id: "session_5h", usedPercent: 0, resetsAt: future)], now: now) == .running)
        #expect(FiveHourWindowState(provider: "claude", bars: [QuotaBar(id: "session_5h", usedPercent: 0, status: "rejected")], now: now) == .running)
        #expect(FiveHourWindowState(provider: "devin", bars: [QuotaBar(id: "daily", usedPercent: 10)], now: now) == .notTracked)
        #expect(FiveHourWindowState(provider: "gemini-cli", bars: [], now: now) == .notTracked)
    }

    @Test func bestAccountIsHiddenWhenAtMostOneAccountCanTakeRequests() {
        func headroom(usable: Int, percent: Double?) -> ProviderHeadroom {
            ProviderHeadroom(provider: "claude", headroomPercent: percent, limitingBarID: "weekly_all", resetsAt: nil, usableCredentials: usable, totalCredentials: 3, bars: [])
        }
        #expect(!headroom(usable: 0, percent: 0).isWorthShowingBesideThePool)
        #expect(!headroom(usable: 1, percent: 40).isWorthShowingBesideThePool)
        #expect(!headroom(usable: 2, percent: nil).isWorthShowingBesideThePool)
        #expect(headroom(usable: 2, percent: 40).isWorthShowingBesideThePool)
    }
}

@Suite("Saved quota recomputed at display time")
struct SavedQuotaTests {
    let savedAt = date("2026-11-14T10:00:00Z")

    func exhaustedSessionAccount() -> Credential {
        Credential(name: "a", authIndex: "a", provider: "claude", quota: QuotaObservation(signals: [
            "Anthropic-Ratelimit-Unified-5h-Utilization": "1",
            "Anthropic-Ratelimit-Unified-5h-Status": "rejected",
            "Anthropic-Ratelimit-Unified-5h-Reset": "2026-11-14T10:30:00Z",
            "Anthropic-Ratelimit-Unified-7d-Utilization": "0.5",
            "Anthropic-Ratelimit-Unified-7d-Reset": "2026-11-18T00:00:00Z"
        ], observedAt: savedAt))
    }

    @Test func headroomOfASavedSnapshotRecoversWhenTheResetPasses() throws {
        let snapshot = HeadroomSnapshot.management(.demo(), credentials: [exhaustedSessionAccount()], now: savedAt)
        let data = try JSONEncoder().encode(snapshot)
        let saved = try JSONDecoder().decode(HeadroomSnapshot.self, from: data)

        let before = QuotaOverview(snapshot: saved, isSaved: true, now: savedAt)
        #expect(before.lowestHeadroom == 0)
        #expect(before.savedAt == savedAt)

        let afterReset = QuotaOverview(snapshot: saved, isSaved: true, now: date("2026-11-14T10:31:00Z"))
        #expect(afterReset.lowestHeadroom == 50)
        #expect(afterReset.headroom.first?.limitingBarID == "weekly_all")
        #expect(afterReset.pools.first?.window(.session5h)?.remainingPercent == 100)
    }

    @Test func savedCooldownEndMakesTheAccountUsableAgain() throws {
        let cooling = Credential(
            name: "c", authIndex: "c", provider: "claude",
            quota: QuotaObservation(signals: ["Anthropic-Ratelimit-Unified-7d-Utilization": "0.4"], observedAt: savedAt),
            cooldowns: [Cooldown(scope: "credential", reason: "quota", retryAt: date("2026-11-14T10:20:00Z"))]
        )
        let snapshot = HeadroomSnapshot.management(.demo(), credentials: [cooling], now: savedAt)
        #expect(snapshot.headroom(at: savedAt).first?.usableCredentials == 0)
        #expect(snapshot.headroom(at: savedAt).first?.headroomPercent == 0)
        let later = snapshot.headroom(at: date("2026-11-14T10:21:00Z"))
        #expect(later.first?.usableCredentials == 1)
        #expect(later.first?.headroomPercent == 60)
    }

    @Test func providerKnownOnlyFromTheFleetSummaryIsKept() {
        let summaryOnly = ProviderHeadroom(provider: "kimi", headroomPercent: 70, limitingBarID: "weekly_all", resetsAt: nil, usableCredentials: 1, totalCredentials: 0, bars: [])
        let snapshot = HeadroomSnapshot(serverID: UUID(), serverName: "s", isDemo: false, generatedAt: savedAt, source: .fleetLimits, providers: [summaryOnly])
        #expect(snapshot.headroom(at: savedAt) == [summaryOnly])
    }
}

@Suite("Account summaries")
struct AccountSummaryDetailTests {
    let now = date("2026-11-14T10:00:00Z")

    @Test func fleetModelCooldownsAreKeptBesideCredentialWideOnes() throws {
        let json = """
        {"label":"claude-1","provider":"claude","plan":null,"state":"active","bars":[{"id":"weekly_all","percent":40}],
         "cooldowns":[{"scope":"model","model":"claude-opus-5-5","reason":"quota","until":"2026-11-14T12:00:00Z"},
                      {"scope":"model","model":"claude-sonnet-5-5","reason":"quota","until":"2026-11-14T11:00:00Z"},
                      {"scope":"model","model":"claude-haiku-5-5","reason":"quota","until":"2026-11-14T09:00:00Z"}]}
        """
        let credential = try JSONDecoder.wire().decode(FleetCredential.self, from: Data(json.utf8))
        let summary = AccountSummary(fleet: credential, now: now)
        #expect(summary.blockedUntil == nil)
        #expect(summary.modelCooldowns == [
            ModelCooldown(model: "claude-sonnet-5-5", until: date("2026-11-14T11:00:00Z")),
            ModelCooldown(model: "claude-opus-5-5", until: date("2026-11-14T12:00:00Z"))
        ])
    }

    @Test func managementModelCooldownsAreListedToo() {
        let credential = Credential(name: "a", authIndex: "a", provider: "claude", cooldowns: [
            Cooldown(scope: "model", modelKey: "claude-opus-5-5", reason: "quota", retryAt: date("2026-11-14T10:40:00Z")),
            Cooldown(scope: "credential", reason: "quota", retryAt: date("2026-11-14T10:30:00Z"))
        ])
        let summary = AccountSummary(credential: credential, now: now)
        #expect(summary.modelCooldowns == [ModelCooldown(model: "claude-opus-5-5", until: date("2026-11-14T10:40:00Z"))])
        #expect(summary.blockedUntil == date("2026-11-14T10:30:00Z"))
    }

    @Test func cooldownWithoutAnEndBlocksTheAccountWithNoTimeLikeThePool() throws {
        let json = """
        {"label":"claude-1","provider":"claude","plan":null,"state":"cooldown","bars":[{"id":"weekly_all","percent":40}],
         "cooldowns":[{"scope":"credential","reason":"quota","until":null},
                      {"scope":"credential","reason":"quota","until":"2026-11-14T12:00:00Z"}]}
        """
        let credential = try JSONDecoder.wire().decode(FleetCredential.self, from: Data(json.utf8))
        let summary = AccountSummary(fleet: credential, now: now)
        #expect(summary.availability == PoolAccount(fleet: credential).availability)
        #expect(summary.blockedUntil == nil)
        #expect(summary.block(at: now) == PoolAccount.Block(until: nil, reason: .cooldown))

        let management = Credential(name: "a", authIndex: "a", provider: "claude", cooldowns: [Cooldown(scope: "credential", reason: "quota", retryAt: nil)])
        let managementSummary = AccountSummary(credential: management, now: now)
        #expect(managementSummary.availability == PoolAccount(credential: management, now: now).availability)
        #expect(managementSummary.block(at: now) == PoolAccount.Block(until: nil, reason: .cooldown))
    }

    @Test func fleetCooldownStateWithoutCredentialWideCooldownsIsNotABlock() throws {
        let json = """
        {"label":"claude-1","provider":"claude","plan":null,"state":"cooldown","bars":[{"id":"weekly_all","percent":40}],
         "cooldowns":[{"scope":"model","model":"claude-opus-5-5","reason":"quota","until":null}]}
        """
        let credential = try JSONDecoder.wire().decode(FleetCredential.self, from: Data(json.utf8))
        #expect(AccountSummary(fleet: credential, now: now).block(at: now) == nil)
        #expect(PoolAccount(fleet: credential).availability == .available)
    }
}

@Suite("Selection after removing a server")
struct SelectionAfterRemovalTests {
    let removed = UUID()
    let other = UUID()

    @Test func removingTheSelectedServerMovesToTheFallback() {
        #expect(SelectionAfterRemoval(removing: removed, selected: removed, fallback: other) == .select(other))
    }

    @Test func removingTheLastServerClearsTheSelection() {
        #expect(SelectionAfterRemoval(removing: removed, selected: removed, fallback: nil) == .clear)
        #expect(SelectionAfterRemoval(removing: removed, selected: removed, fallback: removed) == .clear)
    }

    @Test func removingAnotherServerKeepsTheSelection() {
        #expect(SelectionAfterRemoval(removing: removed, selected: other, fallback: other) == .keep)
    }
}

@Suite("Selection after saving a server")
struct SelectionAfterSaveTests {
    let saved = UUID()
    let demo = UUID()

    @Test func addingTheFirstRealServerOpensItEvenWhenTheDemoIsSelected() {
        #expect(SelectionAfterSave(saving: saved, selected: demo, selectionExists: true, savedBecameDefault: true) == .select)
    }

    @Test func addingAnotherServerKeepsTheCurrentOne() {
        #expect(SelectionAfterSave(saving: saved, selected: demo, selectionExists: true, savedBecameDefault: false) == .keep)
    }

    @Test func addingAServerWithNothingSelectedOpensIt() {
        #expect(SelectionAfterSave(saving: saved, selected: nil, selectionExists: false, savedBecameDefault: false) == .select)
        #expect(SelectionAfterSave(saving: saved, selected: demo, selectionExists: false, savedBecameDefault: false) == .select)
    }

    @Test func editingTheSelectedServerReselectsIt() {
        #expect(SelectionAfterSave(saving: saved, selected: saved, selectionExists: true, savedBecameDefault: false) == .select)
    }
}

@Suite("Section after switching servers")
struct SectionAfterSwitchTests {
    let management = ["overview", "accounts", "usage", "models", "settings"]
    let clientKey = ["limits", "models", "settings"]

    @Test func tabsKeepTheCurrentSectionWhenTheNewServerHasIt() {
        #expect(SectionAfterSwitch.section(current: "models", available: clientKey, keepsCurrent: true) == "models")
        #expect(SectionAfterSwitch.section(current: "settings", available: management, keepsCurrent: true) == "settings")
    }

    @Test func tabsFallBackToTheFirstSectionWhenTheNewServerLacksIt() {
        #expect(SectionAfterSwitch.section(current: "usage", available: clientKey, keepsCurrent: true) == "limits")
        #expect(SectionAfterSwitch.section(current: nil, available: management, keepsCurrent: true) == "overview")
    }

    @Test func deepLinksAndTheSplitViewAlwaysOpenTheFirstSection() {
        #expect(SectionAfterSwitch.section(current: "models", available: clientKey, keepsCurrent: false) == "limits")
    }
}
