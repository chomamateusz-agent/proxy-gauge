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
}

public enum HeadroomCalculator {
    public static func fromCredentials(_ credentials: [Credential], now: Date) -> [ProviderHeadroom] {
        let grouped = Dictionary(grouping: credentials, by: \.provider)
        return grouped.map { provider, members in
            let usable = members.filter { credential in
                let state = credential.state(at: now)
                return state == .active || state == .error && !credential.requiresSignIn
            }
            let bars = bestBars(usable.map(\.quotaBars), now: now)
            return makeHeadroom(provider, bars: bars, usable: usable.count, total: members.count)
        }
        .sortedForDisplay()
    }

    public static func fromFleet(_ limits: FleetLimits) -> [ProviderHeadroom] {
        let totals = Dictionary(grouping: limits.credentials, by: \.provider).mapValues(\.count)
        let providers = Set(limits.summary.keys).union(totals.keys)
        return providers.map { name in
            let summary = limits.summary[name]
            let bars = (summary?.bars ?? [:]).map { id, bar in
                QuotaBar(id: id, usedPercent: bar.percent, resetsAt: bar.resetsAt)
            }
            .sortedForDisplay()
            return makeHeadroom(name, bars: bars, usable: summary?.usableCredentials ?? 0, total: totals[name] ?? 0)
        }
        .sortedForDisplay()
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

    private static func makeHeadroom(_ name: String, bars: [QuotaBar], usable: Int, total: Int) -> ProviderHeadroom {
        let limiting = bars.filter { $0.usedPercent != nil }.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
        let headroom = usable == 0 && total > 0 ? 0 : limiting?.headroomPercent
        return ProviderHeadroom(
            provider: name,
            headroomPercent: headroom,
            limitingBarID: limiting?.id,
            resetsAt: limiting?.resetsAt,
            usableCredentials: usable,
            totalCredentials: total,
            bars: bars
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
