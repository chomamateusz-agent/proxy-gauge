import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Passive quota signals")
struct SignalQuotaParserTests {
    let sampled = date("2026-11-14T10:00:00Z")

    @Test func claudeUtilisationIsAFraction() {
        let observation = QuotaObservation(signals: [
            "anthropic-ratelimit-unified-5h-utilization": "0.4234",
            "Anthropic-Ratelimit-Unified-5h-Status": "ALLOWED_WARNING",
            "Anthropic-Ratelimit-Unified-5h-Reset": "2026-11-14T12:00:00Z"
        ], observedAt: sampled)
        let bars = SignalQuotaParser.bars(provider: "Claude", observations: [observation])
        #expect(bars == [QuotaBar(id: "session_5h", usedPercent: 42.3, status: "allowed_warning", resetsAt: date("2026-11-14T12:00:00Z"), sampledAt: sampled)])
    }

    @Test func codexWindowMinutesDecideTheBar() {
        let observation = QuotaObservation(signals: [
            "X-Codex-Primary-Used-Percent": "71",
            "X-Codex-Primary-Window-Minutes": "10080",
            "X-Codex-Primary-Reset-After-Seconds": "3600",
            "X-Codex-Secondary-Used-Percent": "12.25",
            "X-Codex-Secondary-Window-Minutes": "60",
            "X-Codex-Secondary-Reset-At": "1794657600",
            "X-Codex-Plan-Type": "Pro"
        ], observedAt: sampled)
        let bars = SignalQuotaParser.bars(provider: "codex", observations: [observation])
        #expect(bars.map(\.id) == ["weekly_all", "window_60m"])
        #expect(bars[0].usedPercent == 71)
        #expect(bars[0].resetsAt == sampled.addingTimeInterval(3600))
        #expect(bars[1].usedPercent == 12.3)
        #expect(bars[1].resetsAt == Date(timeIntervalSince1970: 1_794_657_600))
        #expect(SignalQuotaParser.plan(provider: "codex", observations: [observation]) == "pro")
    }

    @Test func codexWindowWithoutMinutesIsSkipped() {
        let observation = QuotaObservation(signals: ["X-Codex-Primary-Used-Percent": "50"], observedAt: sampled)
        #expect(SignalQuotaParser.bars(provider: "codex", observations: [observation]).isEmpty)
    }

    @Test func freshestObservationWinsPerWindow() {
        let older = QuotaObservation(signals: ["Anthropic-Ratelimit-Unified-7d-Utilization": "0.9", "Anthropic-Ratelimit-Unified-5h-Utilization": "0.1"], observedAt: sampled.addingTimeInterval(-600))
        let newer = QuotaObservation(signals: ["Anthropic-Ratelimit-Unified-7d-Utilization": "0.95"], observedAt: sampled)
        let bars = Dictionary(uniqueKeysWithValues: SignalQuotaParser.bars(provider: "claude", observations: [older, newer]).map { ($0.id, $0) })
        #expect(bars["weekly_all"]?.usedPercent == 95)
        #expect(bars["session_5h"]?.usedPercent == 10)
    }

    @Test func devinReportsRemainingPercent() {
        let observation = QuotaObservation(signals: ["daily_quota_remaining_percent": "55%", "weekly_quota_remaining_percent": "80"], observedAt: sampled)
        let bars = SignalQuotaParser.bars(provider: "devin", observations: [observation])
        #expect(bars.map(\.usedPercent) == [45, 20])
    }

    @Test func unknownProvidersHaveNoBars() {
        #expect(SignalQuotaParser.bars(provider: "gemini-cli", observations: [QuotaObservation(signals: ["x": "1"], observedAt: sampled)]).isEmpty)
    }

    @Test func malformedValuesAreUnknownNotZero() {
        let observation = QuotaObservation(signals: ["Anthropic-Ratelimit-Unified-5h-Utilization": "n/a", "Anthropic-Ratelimit-Unified-5h-Status": "allowed"], observedAt: sampled)
        let bar = SignalQuotaParser.bars(provider: "claude", observations: [observation]).first
        #expect(bar?.usedPercent == nil)
        #expect(bar?.headroomPercent == nil)
    }
}

@Suite("Headroom")
struct HeadroomTests {
    let now = date("2026-11-14T10:00:00Z")

    func claude(_ name: String, session: Double, weekly: Double, reset: String = "2026-11-14T12:00:00Z", disabled: Bool = false, cooldownUntil: String? = nil) -> Credential {
        Credential(
            name: name,
            authIndex: name,
            provider: "claude",
            disabled: disabled,
            quota: QuotaObservation(signals: [
                "Anthropic-Ratelimit-Unified-5h-Utilization": String(session / 100),
                "Anthropic-Ratelimit-Unified-5h-Reset": reset,
                "Anthropic-Ratelimit-Unified-7d-Utilization": String(weekly / 100)
            ], observedAt: now),
            cooldowns: cooldownUntil.map { [Cooldown(scope: "credential", reason: "quota", retryAt: date($0))] } ?? []
        )
    }

    @Test func providerHeadroomIsTheBindingWindowOfTheBestAccounts() {
        let credentials = [claude("a", session: 80, weekly: 30), claude("b", session: 20, weekly: 60)]
        let headroom = HeadroomCalculator.fromCredentials(credentials, now: now)
        #expect(headroom.count == 1)
        #expect(headroom[0].bars.map(\.usedPercent) == [20, 30])
        #expect(headroom[0].headroomPercent == 70)
        #expect(headroom[0].limitingBarID == "weekly_all")
        #expect(headroom[0].usableCredentials == 2)
    }

    @Test func disabledAndCoolingAccountsDoNotContribute() {
        let credentials = [
            claude("a", session: 10, weekly: 10, disabled: true),
            claude("b", session: 5, weekly: 5, cooldownUntil: "2026-11-14T11:00:00Z"),
            claude("c", session: 50, weekly: 40)
        ]
        let headroom = HeadroomCalculator.fromCredentials(credentials, now: now)[0]
        #expect(headroom.headroomPercent == 50)
        #expect(headroom.usableCredentials == 1)
        #expect(headroom.totalCredentials == 3)
    }

    @Test func expiredCooldownNoLongerBlocks() {
        let credential = claude("b", session: 5, weekly: 5, cooldownUntil: "2026-11-14T09:00:00Z")
        #expect(credential.state(at: now) == .active)
    }

    @Test func passedResetCountsAsEmptyWindow() {
        let credentials = [claude("a", session: 100, weekly: 10, reset: "2026-11-14T09:00:00Z")]
        let headroom = HeadroomCalculator.fromCredentials(credentials, now: now)[0]
        #expect(headroom.bars.first { $0.id == "session_5h" }?.usedPercent == 0)
        #expect(headroom.headroomPercent == 90)
    }

    @Test func noUsableAccountsMeansNoHeadroom() {
        let headroom = HeadroomCalculator.fromCredentials([claude("a", session: 1, weekly: 1, disabled: true)], now: now)[0]
        #expect(headroom.headroomPercent == 0)
    }

    @Test func providersWithoutSignalsAreUnknown() {
        let credential = Credential(name: "g", authIndex: "g", provider: "gemini-cli")
        let headroom = HeadroomCalculator.fromCredentials([credential], now: now)[0]
        #expect(headroom.headroomPercent == nil)
        #expect(headroom.usableCredentials == 1)
    }

    @Test func overUsedPercentClampsHeadroomAtZero() {
        #expect(QuotaBar(id: "x", usedPercent: 104).headroomPercent == 0)
    }

    @Test func accountCountsGroupByProviderAndState() {
        let credentials = [
            claude("a", session: 1, weekly: 1),
            claude("b", session: 1, weekly: 1, disabled: true),
            claude("c", session: 1, weekly: 1, cooldownUntil: "2026-11-14T11:00:00Z"),
            Credential(name: "x", authIndex: "x", provider: "codex", status: "error")
        ]
        let counts = AccountCounts.tally(credentials, now: now)
        #expect(counts.map(\.provider) == ["claude", "codex"])
        #expect(counts[0].count(.active) == 1)
        #expect(counts[0].count(.disabled) == 1)
        #expect(counts[0].count(.cooldown) == 1)
        #expect(counts[1].count(.error) == 1)
        #expect(counts[0].total == 3)
    }

    @Test func providerNamesAreReadable() {
        #expect(ProviderCatalog.displayName("gemini-cli") == "Gemini CLI")
        #expect(ProviderCatalog.displayName("new_vendor-x") == "New Vendor X")
    }

    @Test func windowsSortSessionFirst() {
        let bars = [QuotaBar(id: "weekly_all", usedPercent: 1), QuotaBar(id: "window_60m", usedPercent: 1), QuotaBar(id: "session_5h", usedPercent: 1)]
        #expect(bars.sortedForDisplay().map(\.id) == ["session_5h", "weekly_all", "window_60m"])
        #expect(QuotaWindow(barID: "window_60m") == .minutes(60))
    }
}

@Suite("Usage summary")
struct UsageSummaryTests {
    @Test func bucketsAlignToTheNewestEnd() {
        let a = Credential(name: "a", authIndex: "a", provider: "claude", success: 10, failed: 1, recentRequests: [
            RequestBucket(time: "09:40-09:50", success: 1, failed: 0), RequestBucket(time: "09:50-10:00", success: 2, failed: 1)
        ])
        let b = Credential(name: "b", authIndex: "b", provider: "codex", success: 5, failed: 0, recentRequests: [
            RequestBucket(time: "09:50-10:00", success: 3, failed: 0)
        ])
        let summary = UsageSummary.from(credentials: [a, b], keyCounters: [ProviderKeyCounters(provider: "codex", keyCount: 1, success: 7, failed: 2)])
        #expect(summary.buckets.map(\.success) == [1, 5])
        #expect(summary.buckets.map(\.failed) == [0, 1])
        #expect(summary.buckets.map(\.label) == ["09:40-09:50", "09:50-10:00"])
        #expect(summary.total == 25)
        #expect(summary.providers.map(\.provider) == ["codex", "claude"])
        #expect(summary.failureRate == 3.0 / 25.0)
    }

    @Test(arguments: [
        ("22:00-22:10", DateComponents(hour: 22, minute: 0)),
        ("09:50-10:00", DateComponents(hour: 9, minute: 50)),
        ("7:05-7:15", DateComponents(hour: 7, minute: 5)),
        ("", nil),
        ("24:00-00:10", nil),
        ("noon-later", nil)
    ])
    func bucketStartTimeIsReadFromTheServerLabel(label: String, expected: DateComponents?) {
        #expect(UsageBucket(index: 0, label: label, success: 0, failed: 0).startClockTime == expected)
    }

    @Test func emptyServerHasNoFailureRate() {
        let summary = UsageSummary.from(credentials: [], keyCounters: [])
        #expect(summary.failureRate == nil)
        #expect(summary.buckets.isEmpty)
    }
}
