import Foundation

public struct PoolAccount: Codable, Sendable, Equatable, Hashable {
    public enum Availability: Codable, Sendable, Equatable, Hashable {
        case available
        case disabled
        case blocked(until: Date?)
        case needsSignIn

        public init(state: CredentialState, requiresSignIn: Bool, credentialCooldownEnds: [Date?]) {
            if state == .disabled {
                self = .disabled
            } else if requiresSignIn {
                self = .needsSignIn
            } else if state == .cooldown, !credentialCooldownEnds.isEmpty {
                self = .blocked(until: credentialCooldownEnds.contains(nil) ? nil : credentialCooldownEnds.compactMap(\.self).max())
            } else {
                self = .available
            }
        }
    }

    public struct Block: Codable, Sendable, Equatable, Hashable {
        public enum Reason: Codable, Sendable, Equatable, Hashable {
            case windowAtLimit(String)
            case cooldown
            case signIn
        }

        public var until: Date?
        public var reason: Reason

        public init(until: Date?, reason: Reason) {
            self.until = until
            self.reason = reason
        }
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
        let availability = Availability(
            state: credential.state(at: now),
            requiresSignIn: credential.requiresSignIn,
            credentialCooldownEnds: credential.activeCooldowns(at: now).filter(\.isCredentialWide).map(\.retryAt)
        )
        self.init(provider: credential.provider, availability: availability, bars: QuotaMerge.bars(passive: credential.quotaBars, active: active), credentialID: credential.stableID)
    }

    func applying(_ active: ActiveQuota?) -> PoolAccount {
        var updated = self
        updated.bars = QuotaMerge.bars(passive: bars, active: active)
        return updated
    }

    public init(fleet credential: FleetCredential) {
        let availability = Availability(
            state: credential.credentialState,
            requiresSignIn: false,
            credentialCooldownEnds: credential.cooldowns.filter { $0.scope != "model" }.map(\.until)
        )
        self.init(provider: credential.provider, availability: availability, bars: credential.bars.map(\.quotaBar))
    }

    enum Contribution: Equatable {
        case remaining(Double, blockedBy: Block?)
        case unknown
        case noWindowRunning(blockedBy: Block?)
        case leftOut
    }

    var countsTowardCapacity: Bool { availability != .disabled }

    public func block(for barID: String?, at now: Date) -> Block? {
        guard countsTowardCapacity else { return nil }
        let held = heldBlock(at: now)
        let exhausted = bars.filter { $0.id != barID && $0.window.limitsWholeAccount && $0.isAtLimit(at: now) }
        guard let latestExhausted = exhausted.max(by: { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }) else { return held }
        let ends = exhausted.map(\.resetsAt) + (held.map { [$0.until] } ?? [])
        let until = ends.contains(nil) ? nil : ends.compactMap(\.self).max()
        let reason: Block.Reason
        if held?.reason == .signIn {
            reason = .signIn
        } else if let held, let reset = latestExhausted.resetsAt,
                  held.until.map({ $0.timeIntervalSince(reset) > 60 }) ?? true {
            reason = .cooldown
        } else {
            reason = .windowAtLimit(latestExhausted.id)
        }
        return Block(until: until, reason: reason)
    }

    private func heldBlock(at now: Date) -> Block? {
        switch availability {
        case .needsSignIn: Block(until: nil, reason: .signIn)
        case .blocked(let until) where until.map { $0 > now } ?? true: Block(until: until, reason: .cooldown)
        case .available, .disabled, .blocked: nil
        }
    }

    func hasIdleFiveHourWindow(at now: Date) -> Bool {
        guard countsTowardCapacity, case .noWindowRunning = contribution(in: FiveHourWindowState.barID, at: now) else { return false }
        return true
    }

    func isUsable(at now: Date) -> Bool {
        countsTowardCapacity && block(for: nil, at: now) == nil
    }

    func contribution(in barID: String, at now: Date) -> Contribution {
        let bar = bars.first { $0.id == barID }
        let tracksFiveHourWindow = barID == FiveHourWindowState.barID && ProviderCatalog.reportsFiveHourWindow(provider)
        if bar?.startsOnUse(provider: provider, at: now) == true {
            return .noWindowRunning(blockedBy: block(for: barID, at: now))
        }
        if tracksFiveHourWindow, bar?.usedPercent == nil, bar?.status != QuotaBar.rejectedStatus { return .leftOut }
        guard let remaining = bar?.remainingPercent(at: now) else { return .unknown }
        return .remaining(remaining, blockedBy: block(for: barID, at: now))
    }

    func remainingPercent(in barID: String, at now: Date) -> Double? {
        switch contribution(in: barID, at: now) {
        case .remaining(let percent, _): percent
        case .noWindowRunning: 100
        case .unknown, .leftOut: nil
        }
    }

    func usablePercent(in barID: String, at now: Date) -> Double? {
        switch contribution(in: barID, at: now) {
        case .remaining(let percent, blockedBy: nil): percent
        case .noWindowRunning(blockedBy: nil): 100
        case .remaining, .noWindowRunning: 0
        case .unknown, .leftOut: nil
        }
    }

    func nextIncrease(in barID: String, at now: Date) -> Date? {
        let remaining = remainingPercent(in: barID, at: now) ?? 0
        let usable = usablePercent(in: barID, at: now) ?? 0
        return changeDates(after: now).first { date in
            (remainingPercent(in: barID, at: date) ?? 0) > remaining || (usablePercent(in: barID, at: date) ?? 0) > usable
        }
    }

    func changeDates(after now: Date) -> [Date] {
        var dates = bars.compactMap(\.resetsAt)
        if case .blocked(let until?) = availability { dates.append(until) }
        return Set(dates).filter { $0 > now }.sorted()
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
    public var accountsLeftOut: Int
    public var accountsCountedAsFull: Int
    public var remainingPercent: Double
    public var usablePercent: Double
    public var blockedUntil: Date?
    public var blockedPercentClearingFirst: Double?
    public var blockClearsAtOnce: Bool
    public var blockReason: PoolAccount.Block.Reason?
    public var nextIncreaseAt: Date?
    public var latestSampleAt: Date?
    public var label: String?

    public var id: String { barID }
    public var window: QuotaWindow { QuotaWindow(barID: barID) }
    public var capacityPercent: Double { Double(accounts) * 100 }
    public var knownAccounts: Int { accounts - unknownAccounts }
    public var blockedPercent: Double { max(0, remainingPercent - usablePercent) }
    public var hasBlockedQuota: Bool { blockedPercent > 0 }

    public var remainingShareOfKnown: Double? {
        shareOfKnown(remainingPercent)
    }

    public var usableShareOfKnown: Double? {
        shareOfKnown(usablePercent)
    }

    private func shareOfKnown(_ percent: Double) -> Double? {
        knownAccounts > 0 ? percent / (Double(knownAccounts) * 100) : nil
    }

    public func isMoreConstrained(than other: PooledWindow) -> Bool {
        (usableShareOfKnown ?? 1, remainingShareOfKnown ?? 1) < (other.usableShareOfKnown ?? 1, other.remainingShareOfKnown ?? 1)
    }

    public init(
        barID: String,
        accounts: Int,
        unknownAccounts: Int,
        accountsLeftOut: Int = 0,
        accountsCountedAsFull: Int = 0,
        remainingPercent: Double,
        usablePercent: Double? = nil,
        blockedUntil: Date? = nil,
        blockedPercentClearingFirst: Double? = nil,
        blockClearsAtOnce: Bool = true,
        blockReason: PoolAccount.Block.Reason? = nil,
        nextIncreaseAt: Date?,
        latestSampleAt: Date?,
        label: String? = nil
    ) {
        self.barID = barID
        self.accounts = accounts
        self.unknownAccounts = unknownAccounts
        self.accountsLeftOut = accountsLeftOut
        self.accountsCountedAsFull = accountsCountedAsFull
        self.remainingPercent = remainingPercent
        self.usablePercent = usablePercent ?? remainingPercent
        self.blockedUntil = blockedUntil
        self.blockedPercentClearingFirst = blockedPercentClearingFirst
        self.blockClearsAtOnce = blockClearsAtOnce
        self.blockReason = blockReason
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
        windows.filter { $0.knownAccounts > 0 }.min { $0.isMoreConstrained(than: $1) }
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
        pools.compactMap { pool in pool.bindingWindow.map { (pool: pool, binding: $0) } }
            .min { $0.binding.isMoreConstrained(than: $1.binding) }?.pool
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
        let tally = WindowTally(members.map { $0.contribution(in: barID, at: now) })
        let earliestEnd = tally.blocked.compactMap(\.block.until).min()
        let firstGroup = tally.blocked.filter { entry in
            guard let earliestEnd else { return entry.block.until == nil }
            return entry.block.until.map { $0.timeIntervalSince(earliestEnd) <= 60 } ?? false
        }
        let firstToClear = firstGroup.max { ($0.block.until ?? .distantFuture) < ($1.block.until ?? .distantFuture) }
        return PooledWindow(
            barID: barID,
            accounts: members.count - tally.leftOut,
            unknownAccounts: tally.unknown,
            accountsLeftOut: tally.leftOut,
            accountsCountedAsFull: tally.countedAsFull,
            remainingPercent: tally.remaining,
            usablePercent: tally.usable,
            blockedUntil: firstToClear?.block.until,
            blockedPercentClearingFirst: firstGroup.isEmpty ? nil : firstGroup.map(\.percent).reduce(0, +),
            blockClearsAtOnce: firstGroup.count == tally.blocked.count,
            blockReason: firstToClear?.block.reason,
            nextIncreaseAt: members.compactMap { $0.nextIncrease(in: barID, at: now) }.min(),
            latestSampleAt: members.compactMap { $0.sampledAt(in: barID) }.max(),
            label: members.lazy.compactMap { $0.label(in: barID) }.first
        )
    }
}

private struct WindowTally {
    var remaining = 0.0
    var usable = 0.0
    var unknown = 0
    var countedAsFull = 0
    var leftOut = 0
    var blocked: [(percent: Double, block: PoolAccount.Block)] = []

    init(_ contributions: [PoolAccount.Contribution]) {
        for contribution in contributions {
            switch contribution {
            case .remaining(let percent, blockedBy: nil):
                remaining += percent
                usable += percent
            case .remaining(let percent, blockedBy: let block?):
                remaining += percent
                if percent > 0 { blocked.append((percent, block)) }
            case .noWindowRunning(blockedBy: nil):
                remaining += 100
                usable += 100
                countedAsFull += 1
            case .noWindowRunning(blockedBy: let block?):
                remaining += 100
                countedAsFull += 1
                blocked.append((100, block))
            case .leftOut:
                leftOut += 1
            case .unknown:
                unknown += 1
            }
        }
    }
}
