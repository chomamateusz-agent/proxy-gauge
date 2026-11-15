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

    public init(provider: String, availability: Availability, bars: [QuotaBar]) {
        self.provider = provider
        self.availability = availability
        self.bars = bars
    }

    public init(credential: Credential, now: Date) {
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
        self.init(provider: credential.provider, availability: availability, bars: credential.quotaBars)
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

    var countsTowardCapacity: Bool { availability != .disabled }

    func isBlocked(at now: Date) -> Bool {
        guard case .blocked(let until) = availability else { return false }
        return until.map { $0 > now } ?? true
    }

    func remainingPercent(in barID: String, at now: Date) -> Double? {
        if isBlocked(at: now) { return 0 }
        guard let bar = bars.first(where: { $0.id == barID }) else { return nil }
        if bar.hasReset(at: now) { return 100 }
        if bar.status == "rejected" { return 0 }
        return bar.headroomPercent
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
}

public struct PooledWindow: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var barID: String
    public var accounts: Int
    public var unknownAccounts: Int
    public var remainingPercent: Double
    public var nextIncreaseAt: Date?
    public var latestSampleAt: Date?

    public var id: String { barID }
    public var window: QuotaWindow { QuotaWindow(barID: barID) }
    public var capacityPercent: Double { Double(accounts) * 100 }
    public var knownAccounts: Int { accounts - unknownAccounts }

    public var remainingShareOfKnown: Double? {
        knownAccounts > 0 ? remainingPercent / (Double(knownAccounts) * 100) : nil
    }

    public init(barID: String, accounts: Int, unknownAccounts: Int, remainingPercent: Double, nextIncreaseAt: Date?, latestSampleAt: Date?) {
        self.barID = barID
        self.accounts = accounts
        self.unknownAccounts = unknownAccounts
        self.remainingPercent = remainingPercent
        self.nextIncreaseAt = nextIncreaseAt
        self.latestSampleAt = latestSampleAt
    }
}

public struct ProviderPool: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var provider: String
    public var accounts: Int
    public var windows: [PooledWindow]

    public var id: String { provider }

    public init(provider: String, accounts: Int, windows: [PooledWindow]) {
        self.provider = provider
        self.accounts = accounts
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
            .map { provider, members in pool(provider, members: members.filter(\.countsTowardCapacity), now: now) }
            .sorted { ProviderCatalog.sortKey($0.provider) < ProviderCatalog.sortKey($1.provider) }
    }

    public static func mostConstrained(_ pools: [ProviderPool]) -> ProviderPool? {
        pools.filter { $0.bindingWindow != nil }
            .min { ($0.bindingWindow?.remainingShareOfKnown ?? 1) < ($1.bindingWindow?.remainingShareOfKnown ?? 1) }
            ?? pools.first { $0.accounts > 0 }
    }

    private static func pool(_ provider: String, members: [PoolAccount], now: Date) -> ProviderPool {
        let barIDs = Set(members.flatMap { $0.bars.map(\.id) })
        let windows: [PooledWindow] = barIDs.map { window($0, members: members, now: now) }
        return ProviderPool(provider: provider, accounts: members.count, windows: windows.sorted(by: displaysBefore))
    }

    private static func displaysBefore(_ lhs: PooledWindow, _ rhs: PooledWindow) -> Bool {
        let left = lhs.window.sortOrder, right = rhs.window.sortOrder
        return left == right ? lhs.barID < rhs.barID : left < right
    }

    private static func window(_ barID: String, members: [PoolAccount], now: Date) -> PooledWindow {
        let contributions: [Double?] = members.map { $0.remainingPercent(in: barID, at: now) }
        let known: [Double] = contributions.compactMap(\.self)
        return PooledWindow(
            barID: barID,
            accounts: members.count,
            unknownAccounts: contributions.count - known.count,
            remainingPercent: known.reduce(0, +),
            nextIncreaseAt: members.compactMap { $0.nextIncrease(in: barID, at: now) }.min(),
            latestSampleAt: members.compactMap { $0.sampledAt(in: barID) }.max()
        )
    }
}
