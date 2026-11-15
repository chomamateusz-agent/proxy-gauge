import Foundation

public struct PoolAccount: Codable, Sendable, Equatable, Hashable {
    public enum Availability: Codable, Sendable, Equatable, Hashable {
        case available
        case disabled
        case blocked(until: Date?)
    }

    public var provider: String
    public var availability: Availability
    public var bars: [QuotaBar]
    public var credentialID: String?

    public init(provider: String, availability: Availability, bars: [QuotaBar], credentialID: String? = nil) {
        self.provider = provider
        self.availability = availability
        self.bars = bars
        self.credentialID = credentialID
    }

    public init(credential: Credential, active: ActiveQuota? = nil, now: Date) {
        let state = credential.state(at: now)
        let availability: Availability = if state == .disabled {
            .disabled
        } else if credential.requiresSignIn {
            .blocked(until: nil)
        } else if state == .cooldown {
            .blocked(until: credential.activeCredentialCooldown(at: now)?.retryAt)
        } else {
            .available
        }
        self.init(provider: credential.provider, availability: availability, bars: QuotaMerge.bars(passive: credential.quotaBars, active: active), credentialID: credential.stableID)
    }

    func applying(_ active: ActiveQuota?) -> PoolAccount {
        var updated = self
        updated.bars = QuotaMerge.bars(passive: bars, active: active)
        return updated
    }

    public init(fleet credential: FleetCredential) {
        let availability: Availability = switch credential.credentialState {
        case .disabled: .disabled
        case .cooldown: Self.coolingAvailability(credential.cooldowns.filter { $0.scope != "model" })
        case .active, .error: .available
        }
        self.init(provider: credential.provider, availability: availability, bars: credential.bars.map(\.quotaBar))
    }

    private static func coolingAvailability(_ credentialCooldowns: [FleetCooldown]) -> Availability {
        if credentialCooldowns.isEmpty { return .available }
        if credentialCooldowns.contains(where: { $0.until == nil }) { return .blocked(until: nil) }
        return .blocked(until: credentialCooldowns.compactMap(\.until).max())
    }

    enum Contribution: Equatable {
        case remaining(Double)
        case unknown
        case noWindowRunning
    }

    var countsTowardCapacity: Bool { availability != .disabled }

    func isBlocked(at now: Date) -> Bool {
        guard case .blocked(let until) = availability else { return false }
        return until.map { $0 > now } ?? true
    }

    func isUsable(at now: Date) -> Bool {
        countsTowardCapacity && !isBlocked(at: now)
    }

    func contribution(in barID: String, at now: Date) -> Contribution {
        let bar = bars.first { $0.id == barID }
        if bar == nil, barID == FiveHourWindowState.barID, ProviderCatalog.reportsFiveHourWindow(provider), !bars.isEmpty { return .noWindowRunning }
        if isBlocked(at: now) { return .remaining(0) }
        return bar?.remainingPercent(at: now).map(Contribution.remaining) ?? .unknown
    }

    func remainingPercent(in barID: String, at now: Date) -> Double? {
        if case .remaining(let percent) = contribution(in: barID, at: now) { return percent }
        return nil
    }

    func nextIncrease(in barID: String, at now: Date) -> Date? {
        let current = remainingPercent(in: barID, at: now) ?? 0
        return changeDates(in: barID, after: now).first { (remainingPercent(in: barID, at: $0) ?? 0) > current }
    }

    private func changeDates(in barID: String, after now: Date) -> [Date] {
        var dates: [Date] = []
        if case .blocked(let until?) = availability { dates.append(until) }
        if let resetsAt = bars.first(where: { $0.id == barID })?.resetsAt { dates.append(resetsAt) }
        return dates.filter { $0 > now }.sorted()
    }

    func sampledAt(in barID: String) -> Date? {
        bars.first { $0.id == barID }?.sampledAt
    }

    func label(in barID: String) -> String? {
        bars.first { $0.id == barID }?.label
    }
}

public struct PooledWindow: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var barID: String
    public var accounts: Int
    public var unknownAccounts: Int
    public var accountsWithoutRunningWindow: Int
    public var remainingPercent: Double
    public var nextIncreaseAt: Date?
    public var latestSampleAt: Date?
    public var label: String?

    public var id: String { barID }
    public var window: QuotaWindow { QuotaWindow(barID: barID) }
    public var capacityPercent: Double { Double(accounts) * 100 }
    public var knownAccounts: Int { accounts - unknownAccounts }

    public var remainingShareOfKnown: Double? {
        knownAccounts > 0 ? remainingPercent / (Double(knownAccounts) * 100) : nil
    }

    public init(barID: String, accounts: Int, unknownAccounts: Int, accountsWithoutRunningWindow: Int = 0, remainingPercent: Double, nextIncreaseAt: Date?, latestSampleAt: Date?, label: String? = nil) {
        self.barID = barID
        self.accounts = accounts
        self.unknownAccounts = unknownAccounts
        self.accountsWithoutRunningWindow = accountsWithoutRunningWindow
        self.remainingPercent = remainingPercent
        self.nextIncreaseAt = nextIncreaseAt
        self.latestSampleAt = latestSampleAt
        self.label = label
    }
}

public struct ProviderPool: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var provider: String
    public var accounts: Int
    public var totalAccounts: Int
    public var usableAccounts: Int
    public var windows: [PooledWindow]

    public var id: String { provider }

    public init(provider: String, accounts: Int, totalAccounts: Int? = nil, usableAccounts: Int? = nil, windows: [PooledWindow]) {
        self.provider = provider
        self.accounts = accounts
        self.totalAccounts = totalAccounts ?? accounts
        self.usableAccounts = usableAccounts ?? accounts
        self.windows = windows
    }

    public var bindingWindow: PooledWindow? {
        windows.filter { $0.remainingShareOfKnown != nil }.min { ($0.remainingShareOfKnown ?? 1) < ($1.remainingShareOfKnown ?? 1) }
    }

    public func window(_ kind: QuotaWindow) -> PooledWindow? {
        windows.first { $0.window == kind }
    }

    public var nextIncreaseAt: Date? {
        windows.compactMap(\.nextIncreaseAt).min()
    }

    public func headlineWindows(limit: Int) -> [PooledWindow] {
        let preferred = [bindingWindow, window(.session5h), window(.weekly)].compactMap(\.self) + windows
        var chosen: [String] = []
        for candidate in preferred where !chosen.contains(candidate.barID) && chosen.count < limit {
            chosen.append(candidate.barID)
        }
        return windows.filter { chosen.contains($0.barID) }
    }
}

public enum PooledCapacity {
    public static func pools(_ accounts: [PoolAccount], now: Date) -> [ProviderPool] {
        Dictionary(grouping: accounts, by: \.provider)
            .map { provider, members in pool(provider, members: members, now: now) }
            .sorted { ProviderCatalog.sortKey($0.provider) < ProviderCatalog.sortKey($1.provider) }
    }

    public static func mostConstrained(_ pools: [ProviderPool]) -> ProviderPool? {
        pools.filter { $0.bindingWindow != nil }
            .min { ($0.bindingWindow?.remainingShareOfKnown ?? 1) < ($1.bindingWindow?.remainingShareOfKnown ?? 1) }
            ?? pools.first { $0.accounts > 0 }
    }

    private static func pool(_ provider: String, members allMembers: [PoolAccount], now: Date) -> ProviderPool {
        let members = allMembers.filter(\.countsTowardCapacity)
        let barIDs = Set(members.flatMap { $0.bars.map(\.id) })
        let windows: [PooledWindow] = barIDs.map { window($0, members: members, now: now) }
        return ProviderPool(
            provider: provider,
            accounts: members.count,
            totalAccounts: allMembers.count,
            usableAccounts: members.filter { $0.isUsable(at: now) }.count,
            windows: windows.sorted(by: displaysBefore)
        )
    }

    private static func displaysBefore(_ lhs: PooledWindow, _ rhs: PooledWindow) -> Bool {
        let left = lhs.window.sortOrder, right = rhs.window.sortOrder
        return left == right ? lhs.barID < rhs.barID : left < right
    }

    private static func window(_ barID: String, members: [PoolAccount], now: Date) -> PooledWindow {
        let contributions = members.map { $0.contribution(in: barID, at: now) }
        let known = contributions.compactMap { contribution -> Double? in
            if case .remaining(let percent) = contribution { percent } else { nil }
        }
        let withoutRunningWindow = contributions.filter { $0 == .noWindowRunning }.count
        return PooledWindow(
            barID: barID,
            accounts: members.count - withoutRunningWindow,
            unknownAccounts: contributions.filter { $0 == .unknown }.count,
            accountsWithoutRunningWindow: withoutRunningWindow,
            remainingPercent: known.reduce(0, +),
            nextIncreaseAt: members.compactMap { $0.nextIncrease(in: barID, at: now) }.min(),
            latestSampleAt: members.compactMap { $0.sampledAt(in: barID) }.max(),
            label: members.lazy.compactMap { $0.label(in: barID) }.first
        )
    }
}
