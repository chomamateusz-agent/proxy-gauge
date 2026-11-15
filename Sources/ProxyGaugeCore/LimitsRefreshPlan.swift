import Foundation

public struct LimitsRefreshPlan: Sendable, Equatable {
    public struct ProviderGroup: Sendable, Equatable, Identifiable {
        public var provider: String
        public var accounts: [String]
        public var requests: [ActiveRequestKind]
        public var maximumRequestsPerAccount: Int

        public var id: String { provider }
    }

    public struct Waiting: Sendable, Equatable, Identifiable {
        public var credentialID: String
        public var label: String
        public var provider: String
        public var until: Date
        public var because: ActiveRefreshWait

        public var id: String { credentialID }
    }

    public struct Skipped: Sendable, Equatable, Identifiable {
        public var credentialID: String
        public var label: String
        public var provider: String
        public var reason: ActiveRefreshSkip

        public var id: String { credentialID }
    }

    public var groups: [ProviderGroup]
    public var waiting: [Waiting]
    public var skipped: [Skipped]

    public init(groups: [ProviderGroup] = [], waiting: [Waiting] = [], skipped: [Skipped] = []) {
        self.groups = groups
        self.waiting = waiting
        self.skipped = skipped
    }

    public var isEmpty: Bool { groups.isEmpty }

    public var maximumRequests: Int {
        groups.reduce(0) { $0 + $1.accounts.count * $1.maximumRequestsPerAccount }
    }

    public var mayRunPaidCompletion: Bool {
        groups.contains { ActiveRefreshPolicy.mayRunPaidCompletion($0.provider) && $0.requests.contains(.paidKeyCheck) }
    }

    public var usesUnofficialGoogleEndpoints: Bool {
        groups.contains { ActiveRefreshPolicy.usesUnofficialGoogleEndpoints($0.provider) }
    }

    public var unsupportedProviders: [String] {
        var seen = Set<String>()
        return skipped.filter { $0.reason == .unsupported }.map(\.provider).filter { seen.insert($0).inserted }
    }

    public static func make(targets: [ActiveTarget], states: [String: ActiveRefreshState], readings: Set<String> = [], mode: ActiveRefreshMode = .manual, now: Date) -> LimitsRefreshPlan {
        var plan = LimitsRefreshPlan()
        var groups: [String: ProviderGroup] = [:]
        var order: [String] = []
        for target in targets {
            switch ActiveRefreshPolicy.decide(target, state: states[target.credentialID] ?? ActiveRefreshState(), mode: mode, hasReading: readings.contains(target.credentialID), now: now) {
            case .run(let scope):
                if groups[target.provider] == nil { order.append(target.provider) }
                var group = groups[target.provider] ?? ProviderGroup(provider: target.provider, accounts: [], requests: [], maximumRequestsPerAccount: 0)
                group.accounts.append(target.label)
                for kind in ActiveQuotaAdapters.requests(for: target, scope: scope) where !group.requests.contains(kind) {
                    group.requests.append(kind)
                }
                group.maximumRequestsPerAccount = max(group.maximumRequestsPerAccount, ActiveQuotaAdapters.maximumRequests(for: target, scope: scope))
                groups[target.provider] = group
            case .wait(let until, let because):
                plan.waiting.append(Waiting(credentialID: target.credentialID, label: target.label, provider: target.provider, until: until, because: because))
            case .skip(let reason):
                plan.skipped.append(Skipped(credentialID: target.credentialID, label: target.label, provider: target.provider, reason: reason))
            }
        }
        plan.groups = order.compactMap { groups[$0] }.sorted { ProviderCatalog.sortKey($0.provider) < ProviderCatalog.sortKey($1.provider) }
        return plan
    }
}
