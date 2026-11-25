import Foundation

public enum PlanWeight {
    public static func multiplier(provider: String, plan: String?) -> Double? {
        guard provider.lowercased() == "claude", let plan else { return nil }
        let key = plan.lowercased()
            .replacingOccurrences(of: "plan_", with: "")
            .filter { $0.isLetter || $0.isNumber }
        switch key {
        case "max20x", "max20": return 20
        case "max5x", "max5": return 5
        case "pro": return 1
        default: return nil
        }
    }
}

public struct WindowSlot: Sendable, Equatable, Hashable, Identifiable {
    public var barID: String
    public var label: String?
    public var holdsOnlyMonthlyReadings = false

    public init(barID: String, label: String? = nil, holdsOnlyMonthlyReadings: Bool = false) {
        self.barID = barID
        self.label = label
        self.holdsOnlyMonthlyReadings = holdsOnlyMonthlyReadings
    }

    public var id: String { barID }
    public var window: QuotaWindow { QuotaWindow(barID: barID) }
}

public struct SlotReading: Sendable, Equatable, Identifiable {
    public var slot: WindowSlot
    public var remainingPercent: Double?
    public var resetsAt: Date?
    public var bar: QuotaBar?

    public init(slot: WindowSlot, remainingPercent: Double?, resetsAt: Date? = nil, bar: QuotaBar? = nil) {
        self.slot = slot
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.bar = bar
    }

    public var id: String { slot.id }
    public var hasReading: Bool { remainingPercent != nil }
    public var isReported: Bool { bar != nil && remainingPercent != nil }
}

public struct SlotPool: Sendable, Equatable, Identifiable {
    public var slot: WindowSlot
    public var remainingPercent: Double?
    public var covered: Int
    public var total: Int

    public init(slot: WindowSlot, remainingPercent: Double?, covered: Int, total: Int) {
        self.slot = slot
        self.remainingPercent = remainingPercent
        self.covered = covered
        self.total = total
    }

    public var id: String { slot.id }
}

public struct ProviderSlotPools: Sendable, Equatable {
    public var provider: String
    public var slots: [WindowSlot]
    public var pools: [SlotPool]
    public var weighted: Bool
    public var accounts: Int
    public var loaded: Int

    public var hasAnyReading: Bool { pools.contains { $0.covered > 0 } }
}

public struct AccountsStatus: Sendable, Equatable {
    public var accounts: Int
    public var loaded: Int
    public var needAttention: Int

    public init(_ accounts: [AccountSummary]) {
        self.accounts = accounts.count
        loaded = accounts.count(where: \.isLoaded)
        needAttention = accounts.count(where: \.needsAttention)
    }
}

public extension AccountSummary {
    var isLoaded: Bool { !bars.isEmpty }

    var needsAttention: Bool {
        state != .disabled && (availability == .needsSignIn || state == .error || providerCheckFailure != nil)
    }

    var providerCheckFailure: ActiveRefreshFailure? {
        providerCheckState?.lastFailure
    }

    func hasEnded(at now: Date) -> Bool {
        hasEnded || endsAt.map { $0 <= now } == true
    }

    var planWeight: Double? { PlanWeight.multiplier(provider: provider, plan: plan) }

    static func saved(_ accounts: [PoolAccount]) -> [AccountSummary] {
        accounts.enumerated().map { index, account in
            let state: CredentialState = switch account.availability {
            case .available: .active
            case .disabled: .disabled
            case .blocked: .cooldown
            case .needsSignIn: .error
            }
            let blockedUntil: Date? = if case .blocked(let until) = account.availability { until } else { nil }
            return AccountSummary(
                id: account.credentialID ?? "saved-\(index)",
                provider: account.provider,
                label: "",
                state: state,
                bars: account.bars,
                blockedUntil: blockedUntil,
                availability: account.availability,
                requiresSignIn: account.availability == .needsSignIn
            )
        }
    }
}

public enum QuotaSlots {
    static let fixed: [String: [String]] = [
        "claude": [FiveHourWindowState.barID, "weekly_all", "weekly_fable"],
        "codex": [FiveHourWindowState.barID, "weekly_all"],
        "xai": ["weekly_all"]
    ]

    static let monthlyMinutes = (28 * 1_440)...(31 * 1_440)
    static let foldsMonthlyIntoWeekly: Set<String> = ["codex"]

    public static func fixedSlots(for provider: String) -> [String] {
        fixed[provider.lowercased()] ?? []
    }

    static func isMonthly(_ bar: QuotaBar) -> Bool {
        switch bar.window {
        case .monthly: true
        case .minutes(let minutes): monthlyMinutes.contains(minutes)
        default: false
        }
    }

    static func folds(_ provider: String) -> Bool {
        foldsMonthlyIntoWeekly.contains(provider.lowercased())
    }

    public static func bar(_ account: AccountSummary, slot: WindowSlot) -> QuotaBar? {
        if let bar = account.bar(slot.barID) ?? account.bars.first(where: { $0.window == slot.window }) { return bar }
        guard slot.window == .weekly, folds(account.provider) else { return nil }
        return account.bars.first(where: isMonthly)
    }

    public static func slots(provider: String, accounts: [AccountSummary]) -> [WindowSlot] {
        let members = accounts.filter { $0.provider == provider }
        let folding = folds(provider)
        let bars = members.flatMap(\.bars).sortedForDisplay().filter { !folding || !isMonthly($0) }
        var slots = fixedSlots(for: provider).map { WindowSlot(barID: $0) }
        for bar in bars where !slots.contains(where: { $0.window == bar.window }) {
            slots.append(WindowSlot(barID: bar.id))
        }
        return slots
            .map { slot in
                var labelled = slot
                labelled.label = bars.first { $0.window == slot.window && $0.label != nil }?.label
                if folding, slot.window == .weekly {
                    let filling = members.compactMap { bar($0, slot: slot) }
                    labelled.holdsOnlyMonthlyReadings = !filling.isEmpty && filling.allSatisfy(isMonthly)
                }
                return labelled
            }
            .sorted { lhs, rhs in
                lhs.window.sortOrder == rhs.window.sortOrder ? lhs.barID < rhs.barID : lhs.window.sortOrder < rhs.window.sortOrder
            }
    }

    public static func reading(_ account: AccountSummary, slot: WindowSlot, at now: Date) -> SlotReading {
        guard let bar = bar(account, slot: slot) else { return SlotReading(slot: slot, remainingPercent: nil) }
        let upcoming = bar.resetsAt.flatMap { $0 > now ? $0 : nil }
        return SlotReading(slot: slot, remainingPercent: bar.remainingPercent(at: now), resetsAt: upcoming, bar: bar)
    }

    public static func readings(_ account: AccountSummary, slots: [WindowSlot], at now: Date) -> [SlotReading] {
        slots.map { reading(account, slot: $0, at: now) }
    }

    public static func pools(provider: String, accounts allAccounts: [AccountSummary], at now: Date) -> ProviderSlotPools {
        let accounts = allAccounts.filter { $0.provider == provider }
        let slots = slots(provider: provider, accounts: accounts)
        let included = accounts.filter { $0.isLoaded && $0.state != .disabled && !$0.hasEnded(at: now) }
        let claude = included.filter { $0.provider.lowercased() == "claude" }
        let weighted = !claude.isEmpty && claude.allSatisfy { $0.planWeight != nil }
        func weight(_ account: AccountSummary) -> Double {
            weighted ? account.planWeight ?? 1 : 1
        }
        let pools = slots.map { slot -> SlotPool in
            let covering = included.compactMap { account -> (weight: Double, remaining: Double)? in
                let reading = reading(account, slot: slot, at: now)
                guard reading.isReported, let remaining = reading.remainingPercent else { return nil }
                return (weight(account), remaining)
            }
            let totalWeight = covering.map(\.weight).reduce(0, +)
            return SlotPool(
                slot: slot,
                remainingPercent: totalWeight > 0 ? covering.map { $0.weight * $0.remaining }.reduce(0, +) / totalWeight : nil,
                covered: covering.count,
                total: accounts.count
            )
        }
        return ProviderSlotPools(
            provider: provider,
            slots: slots,
            pools: pools,
            weighted: weighted,
            accounts: accounts.count,
            loaded: accounts.count(where: \.isLoaded)
        )
    }
}
