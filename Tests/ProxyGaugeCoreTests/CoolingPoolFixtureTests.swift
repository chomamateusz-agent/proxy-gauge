import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Anonymised live pool with accounts blocked by their weekly limit")
struct CoolingPoolFixtureTests {
    let now = date("2026-11-17T18:48:30Z")
    let fridayUnblock = date("2026-11-20T11:00:02Z")

    func limits() throws -> FleetLimits {
        try JSONDecoder.wire().decode(FleetLimits.self, from: Fixture.data("fleet-limits-cooling-pool.json"))
    }

    func clientKeyPools() throws -> [ProviderPool] {
        HeadroomSnapshot.clientKey(.demo(authMode: .clientKey), limits: try limits(), now: now).pools(at: now)
    }

    func managementPools() throws -> [ProviderPool] {
        let credentials = try limits().credentials.map(ManagementEquivalent.credential)
        return HeadroomSnapshot.management(.demo(), credentials: credentials, now: now).pools(at: now)
    }

    @Test func claudeWindowsAddUpLikeTheManagementPanel() throws {
        let claude = try #require(try clientKeyPools().first { $0.provider == "claude" })
        #expect(claude.totalAccounts == 4)
        #expect(claude.accounts == 3)
        #expect(claude.usableAccounts == 1)

        let weekly = try #require(claude.window(.weekly))
        #expect(weekly.remainingPercent == 36)
        #expect(weekly.capacityPercent == 300)
        #expect(weekly.usablePercent == 36)
        #expect(!weekly.hasBlockedQuota)

        let fable = try #require(claude.window(.weeklyFable))
        #expect(fable.remainingPercent == 168)
        #expect(fable.capacityPercent == 300)
        #expect(fable.usablePercent == 66)
        #expect(fable.blockedPercent == 102)
        #expect(fable.blockedUntil == fridayUnblock)
        #expect(fable.blockedPercentClearingFirst == 58)
        #expect(!fable.blockClearsAtOnce)
        #expect(fable.blockReason == .windowAtLimit("weekly_all"))

        let session = try #require(claude.window(.session5h))
        #expect(session.remainingPercent == 100)
        #expect(session.capacityPercent == 100)
        #expect(session.usablePercent == 0)
        #expect(session.blockedPercent == 100)
        #expect(session.blockedUntil == fridayUnblock)
        #expect(session.blockClearsAtOnce)
        #expect(session.accountsCountedAsFull == 1)
        #expect(session.accountsLeftOut == 2)
    }

    @Test func widgetsLeadWithTheProviderThatCanTakeTheLeastRequests() throws {
        let pools = try clientKeyPools()
        #expect(PooledCapacity.mostConstrained(pools)?.provider == "codex")
        let claude = try #require(pools.first { $0.provider == "claude" })
        #expect(claude.bindingWindow?.window == .session5h)
    }

    @Test func codexWeeklyIsUsedUp() throws {
        let codex = try #require(try clientKeyPools().first { $0.provider == "codex" })
        let weekly = try #require(codex.window(.weekly))
        #expect(weekly.remainingPercent == 0)
        #expect(weekly.capacityPercent == 100)
        #expect(weekly.usablePercent == 0)
        #expect(!weekly.hasBlockedQuota)
        #expect(codex.usableAccounts == 0)
    }

    @Test func bestUsableAccountComesFromTheOnlyAccountThatCanTakeRequests() throws {
        let headroom = HeadroomCalculator.fromFleet(try limits(), now: now)
        let claude = try #require(headroom.first { $0.provider == "claude" })
        #expect(claude.usableCredentials == 1)
        #expect(claude.headroomPercent == 36)
        #expect(claude.limitingBarID == "weekly_all")
    }

    @Test func managementModeGivesTheSameNumbers() throws {
        let management = try managementPools().map(PoolNumbers.init)
        let clientKey = try clientKeyPools().map(PoolNumbers.init)
        #expect(management == clientKey)
        #expect(management.count == 2)
    }
}

private struct PoolNumbers: Equatable {
    struct Window: Equatable {
        var barID: String
        var accounts: Int
        var unknown: Int
        var withoutRunningWindow: Int
        var remaining: Double
        var usable: Double
        var blockedUntil: Date?
        var nextIncreaseAt: Date?
    }

    var provider: String
    var accounts: Int
    var total: Int
    var usable: Int
    var windows: [Window]

    init(_ pool: ProviderPool) {
        provider = pool.provider
        accounts = pool.accounts
        total = pool.totalAccounts
        usable = pool.usableAccounts
        windows = pool.windows.map {
            Window(
                barID: $0.barID,
                accounts: $0.accounts,
                unknown: $0.unknownAccounts,
                withoutRunningWindow: $0.accountsLeftOut,
                remaining: $0.remainingPercent,
                usable: $0.usablePercent,
                blockedUntil: $0.blockedUntil,
                nextIncreaseAt: $0.nextIncreaseAt
            )
        }
    }
}

enum ManagementEquivalent {
    static func credential(_ fleet: FleetCredential) -> Credential {
        var signals: [String: String] = [:]
        for bar in fleet.bars {
            switch fleet.provider {
            case "claude": signals.merge(claudeSignals(bar)) { _, new in new }
            default: signals.merge(codexSignals(bar)) { _, new in new }
            }
        }
        let observedAt = fleet.bars.compactMap(\.sampledAt).max()
        return Credential(
            name: fleet.label,
            authIndex: fleet.label,
            provider: fleet.provider,
            status: fleet.credentialState == .disabled ? "disabled" : "active",
            disabled: fleet.credentialState == .disabled,
            quota: signals.isEmpty ? nil : QuotaObservation(signals: signals, observedAt: observedAt),
            cooldowns: fleet.cooldowns.map { Cooldown(scope: $0.scope, modelKey: $0.model, reason: $0.reason, retryAt: $0.until) }
        )
    }

    static func claudeSignals(_ bar: FleetBar) -> [String: String] {
        let prefix = switch bar.id {
        case "weekly_all": "Anthropic-Ratelimit-Unified-7d-"
        case "weekly_fable": "Anthropic-Ratelimit-Unified-7d_oi-"
        default: "Anthropic-Ratelimit-Unified-5h-"
        }
        var signals = [prefix + "Utilization": String((bar.percent ?? 0) / 100)]
        signals[prefix + "Status"] = bar.status
        signals[prefix + "Reset"] = bar.resetsAt.map { String(Int($0.timeIntervalSince1970)) }
        return signals
    }

    static func codexSignals(_ bar: FleetBar) -> [String: String] {
        var signals = [
            "X-Codex-Primary-Used-Percent": String(bar.percent ?? 0),
            "X-Codex-Primary-Window-Minutes": String(7 * 24 * 60)
        ]
        signals["X-Codex-Primary-Reset-At"] = bar.resetsAt.map { String(Int($0.timeIntervalSince1970)) }
        return signals
    }
}
