import Foundation

public struct ProviderHeadroom: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var provider: String
    public var headroomPercent: Double?
    public var limitingBarID: String?
    public var resetsAt: Date?
    public var usableCredentials: Int
    public var totalCredentials: Int
    public var bars: [QuotaBar]

    public var id: String { provider }

    public init(provider: String, headroomPercent: Double?, limitingBarID: String?, resetsAt: Date?, usableCredentials: Int, totalCredentials: Int, bars: [QuotaBar]) {
        self.provider = provider
        self.headroomPercent = headroomPercent
        self.limitingBarID = limitingBarID
        self.resetsAt = resetsAt
        self.usableCredentials = usableCredentials
        self.totalCredentials = totalCredentials
        self.bars = bars
    }

    public var isWorthShowingBesideThePool: Bool {
        usableCredentials > 1 && headroomPercent != nil
    }
}

public enum HeadroomCalculator {
    public static func fromCredentials(_ credentials: [Credential], active: [String: ActiveQuota] = [:], now: Date) -> [ProviderHeadroom] {
        fromPoolAccounts(credentials.map { PoolAccount(credential: $0, active: active[$0.stableID], now: now) }, now: now)
    }

    public static func fromFleet(_ limits: FleetLimits, now: Date) -> [ProviderHeadroom] {
        let fromCredentials = fromPoolAccounts(limits.credentials.map(PoolAccount.init(fleet:)), now: now)
        let covered = Set(fromCredentials.map(\.provider))
        let summaryOnly = limits.summary.keys.filter { !covered.contains($0) }.map { name in
            fromFleetSummary(name, summary: limits.summary[name], now: now)
        }
        return (fromCredentials + summaryOnly).sortedForDisplay()
    }

    public static func fromPoolAccounts(_ accounts: [PoolAccount], now: Date) -> [ProviderHeadroom] {
        Dictionary(grouping: accounts, by: \.provider).map { provider, members in
            let usable = members.filter { $0.isUsable(at: now) }
            return makeHeadroom(provider, accountBars: usable.map(\.bars), usable: usable.count, total: members.count, now: now)
        }
        .sortedForDisplay()
    }

    private static func fromFleetSummary(_ name: String, summary: FleetProviderSummary?, now: Date) -> ProviderHeadroom {
        let bars = (summary?.bars ?? [:]).map { id, bar in
            QuotaBar(id: id, usedPercent: bar.percent, resetsAt: bar.resetsAt)
        }
        let usable = summary?.usableCredentials ?? 0
        return makeHeadroom(name, accountBars: usable > 0 ? [bars] : [], usable: usable, total: 0, now: now)
    }

    public static func bestBars(_ barSets: [[QuotaBar]], now: Date) -> [QuotaBar] {
        var best: [String: QuotaBar] = [:]
        for bar in barSets.joined() {
            guard let used = bar.effectiveUsedPercent(at: now) else { continue }
            var candidate = bar
            candidate.usedPercent = used
            if bar.hasReset(at: now) { candidate.resetsAt = nil }
            if let current = best[bar.id], let currentUsed = current.usedPercent, currentUsed <= used {
                continue
            }
            best[bar.id] = candidate
        }
        return Array(best.values).sortedForDisplay()
    }

    public static func tightestWindow(_ bars: [QuotaBar], now: Date) -> QuotaBar? {
        bars.sortedForDisplay().compactMap { bar -> QuotaBar? in
            guard let remaining = bar.remainingPercent(at: now) else { return nil }
            var effective = bar
            effective.usedPercent = 100 - remaining
            if bar.hasReset(at: now) { effective.resetsAt = nil }
            return effective
        }
        .reduce(nil) { tightest, bar in
            guard let tightest, let used = tightest.usedPercent, used >= (bar.usedPercent ?? 0) else { return bar }
            return tightest
        }
    }

    private static func makeHeadroom(_ name: String, accountBars: [[QuotaBar]], usable: Int, total: Int, now: Date) -> ProviderHeadroom {
        let best = accountBars.compactMap { tightestWindow($0, now: now) }.reduce(nil) { (best: QuotaBar?, bar: QuotaBar) in
            guard let best, (best.headroomPercent ?? 0) >= (bar.headroomPercent ?? 0) else { return bar }
            return best
        }
        let headroom = usable == 0 && total > 0 ? 0 : best?.headroomPercent
        return ProviderHeadroom(
            provider: name,
            headroomPercent: headroom,
            limitingBarID: best?.id,
            resetsAt: best?.resetsAt,
            usableCredentials: usable,
            totalCredentials: total,
            bars: bestBars(accountBars, now: now)
        )
    }
}

public extension Array where Element == ProviderHeadroom {
    func sortedForDisplay() -> [ProviderHeadroom] {
        sorted { ProviderCatalog.sortKey($0.provider) < ProviderCatalog.sortKey($1.provider) }
    }
}

public struct AccountCounts: Sendable, Equatable, Identifiable {
    public var provider: String
    public var counts: [CredentialState: Int]

    public var id: String { provider }
    public var total: Int { counts.values.reduce(0, +) }

    public func count(_ state: CredentialState) -> Int { counts[state] ?? 0 }

    public static func tally(_ credentials: [Credential], now: Date) -> [AccountCounts] {
        Dictionary(grouping: credentials, by: \.provider)
            .map { provider, members in
                AccountCounts(provider: provider, counts: Dictionary(grouping: members) { $0.state(at: now) }.mapValues(\.count))
            }
            .sorted { ProviderCatalog.sortKey($0.provider) < ProviderCatalog.sortKey($1.provider) }
    }
}

public enum ProviderCatalog {
    private static let names: [String: String] = [
        "claude": "Claude",
        "codex": "Codex",
        "gemini": "Gemini",
        "gemini-cli": "Gemini CLI",
        "vertex": "Vertex",
        "aistudio": "AI Studio",
        "antigravity": "Antigravity",
        "qwen": "Qwen",
        "iflow": "iFlow",
        "kimi": "Kimi",
        "devin": "Devin",
        "xai": "xAI",
        "openai": "OpenAI",
        "openai-compatibility": "OpenAI-compatible"
    ]

    private static let fiveHourProviders: Set<String> = ["claude", "codex"]

    public static func reportsFiveHourWindow(_ provider: String) -> Bool {
        fiveHourProviders.contains(provider.lowercased())
    }

    private static let order = ["claude", "codex", "gemini-cli", "gemini", "antigravity", "vertex", "aistudio", "kimi", "qwen", "devin"]

    public static func displayName(_ provider: String) -> String {
        if let known = names[provider.lowercased()] { return known }
        return provider
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func sortKey(_ provider: String) -> String {
        let index = order.firstIndex(of: provider.lowercased()) ?? order.count
        let padded = String(repeating: "0", count: max(0, 3 - String(index).count)) + String(index)
        return padded + "-" + provider.lowercased()
    }
}
