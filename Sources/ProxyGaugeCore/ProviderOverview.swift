import Foundation

public struct AccountCell: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case remaining(Double)
        case idleCountedAsFull
        case leftOutWithoutRunningWindow
        case unknown
        case notCounted
    }

    public var value: Value
    public var isBlocked: Bool

    public init(value: Value, isBlocked: Bool = false) {
        self.value = value
        self.isBlocked = isBlocked
    }

    init(_ contribution: PoolAccount.Contribution) {
        switch contribution {
        case .remaining(let percent, let block): self.init(value: .remaining(percent), isBlocked: block != nil)
        case .noWindowRunning(let block): self.init(value: .idleCountedAsFull, isBlocked: block != nil)
        case .leftOut: self.init(value: .leftOutWithoutRunningWindow)
        case .unknown: self.init(value: .unknown)
        }
    }

    public var remainingPercent: Double? {
        switch value {
        case .remaining(let percent): percent
        case .idleCountedAsFull: 100
        case .leftOutWithoutRunningWindow, .unknown, .notCounted: nil
        }
    }
}

public struct AccountColumn: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case usable
        case blocked(until: Date?)
        case needsSignIn
        case reportsError
        case disabled
    }

    public var id: String
    public var label: String
    public var name: String
    public var state: CredentialState
    public var status: Status
    public var cells: [String: AccountCell]

    public init(id: String, label: String, name: String? = nil, state: CredentialState, status: Status, cells: [String: AccountCell]) {
        self.id = id
        self.label = label
        self.name = name ?? label
        self.state = state
        self.status = status
        self.cells = cells
    }

    init(account: AccountSummary, name: String, barIDs: [String], now: Date) {
        let pooled = account.poolAccount
        let status: Status = if !pooled.countsTowardCapacity {
            .disabled
        } else if pooled.availability == .needsSignIn {
            .needsSignIn
        } else if let block = pooled.block(for: nil, at: now) {
            .blocked(until: block.until)
        } else if account.state == .error {
            .reportsError
        } else {
            .usable
        }
        let cells = Dictionary(uniqueKeysWithValues: barIDs.map { barID in
            (barID, pooled.countsTowardCapacity ? AccountCell(pooled.contribution(in: barID, at: now)) : AccountCell(value: .notCounted))
        })
        self.init(id: account.id, label: account.label, name: name, state: account.state, status: status, cells: cells)
    }

    public func cell(_ barID: String) -> AccountCell {
        cells[barID] ?? AccountCell(value: .unknown)
    }

    public var isBlocked: Bool {
        switch status {
        case .blocked, .needsSignIn: true
        case .usable, .reportsError, .disabled: false
        }
    }
}

public struct Comeback: Sendable, Equatable {
    public struct Gain: Sendable, Equatable {
        public var barID: String
        public var percent: Double

        public init(barID: String, percent: Double) {
            self.barID = barID
            self.percent = percent
        }
    }

    public enum Kind: Sendable, Equatable {
        case accountsBack
        case windowsReset
        case blockedWithoutEnd
        case needsSignIn
    }

    public var kind: Kind
    public var at: Date?
    public var accounts: [String]
    public var gains: [Gain]

    public init(kind: Kind, at: Date?, accounts: [String], gains: [Gain]) {
        self.kind = kind
        self.at = at
        self.accounts = accounts
        self.gains = gains
    }
}

public struct StateCount: Sendable, Equatable, Hashable {
    public var state: CredentialState
    public var count: Int

    public init(state: CredentialState, count: Int) {
        self.state = state
        self.count = count
    }
}

public struct ProviderOverview: Sendable, Equatable, Identifiable {
    public static let comebackClusterSeconds: TimeInterval = 60
    public static let namedAccountsLimit = 2

    public var pool: ProviderPool
    public var stateCounts: [StateCount]
    public var columns: [AccountColumn]
    public var headline: PooledWindow?
    public var comeback: Comeback?
    public var headlineComeback: Comeback?

    public var id: String { pool.provider }

    public init(pool: ProviderPool, accounts allAccounts: [AccountSummary], now: Date) {
        let accounts = AccountSummary.board(allAccounts.filter { $0.provider == pool.provider })
        let barIDs = pool.windows.map(\.barID)
        self.pool = pool
        stateCounts = CredentialState.allCases.compactMap { state in
            let count = accounts.count { $0.state == state }
            return count > 0 ? StateCount(state: state, count: count) : nil
        }
        let names = Self.shortNames(accounts)
        columns = accounts.map { AccountColumn(account: $0, name: names[$0.id] ?? $0.label, barIDs: barIDs, now: now) }
        headline = Self.tightestGeneralWindow(pool)
        let events = ComebackTimeline(accounts: accounts, names: names, now: now).events
        let comebacks = events.flatMap { $0.comebacks(barIDs: barIDs) }
        let waiting = Self.blockedWithoutEnd(columns)
        comeback = comebacks.first { $0.kind == .accountsBack } ?? waiting ?? comebacks.first
        headlineComeback = headline.flatMap { window in
            events.lazy.flatMap { $0.comebacks(barIDs: [window.barID]) }.first
        } ?? waiting
    }

    public static func all(pools: [ProviderPool], accounts: [AccountSummary], now: Date) -> [ProviderOverview] {
        pools.map { ProviderOverview(pool: $0, accounts: accounts, now: now) }
    }

    public static func tightestGeneralWindow(_ pool: ProviderPool) -> PooledWindow? {
        pool.windows
            .filter { $0.window.limitsWholeAccount && $0.knownAccounts > 0 }
            .min { $0.isMoreConstrained(than: $1) }
            ?? pool.bindingWindow
    }

    public static func shortNames(_ accounts: [AccountSummary]) -> [String: String] {
        let local = accounts.map { account in
            (id: account.id, label: account.label, short: account.label.split(separator: "@", maxSplits: 1).first.map(String.init) ?? account.label)
        }
        let uses = Dictionary(grouping: local, by: \.short).mapValues(\.count)
        return Dictionary(local.map { ($0.id, uses[$0.short] == 1 && !$0.short.isEmpty ? $0.short : $0.label) }, uniquingKeysWith: { first, _ in first })
    }

    public var hasAccountColumns: Bool { !columns.isEmpty && !pool.windows.isEmpty }

    public func total(_ barID: String) -> Double {
        columns.compactMap { $0.cell(barID).remainingPercent }.reduce(0, +)
    }

    public func roundedCells(_ barID: String) -> [String: Int] {
        let exact = columns.compactMap { column in column.cell(barID).remainingPercent.map { (id: column.id, percent: $0) } }
        var whole = exact.map { Int($0.percent.rounded(.down)) }
        let roundedTotal = Int(exact.map(\.percent).reduce(0, +).rounded(.toNearestOrEven))
        let byLargestFraction = exact.indices.sorted { lhs, rhs in
            let left = exact[lhs].percent - Double(whole[lhs]), right = exact[rhs].percent - Double(whole[rhs])
            return left == right ? lhs < rhs : left > right
        }
        for index in byLargestFraction.prefix(max(0, roundedTotal - whole.reduce(0, +))) {
            whole[index] += 1
        }
        return Dictionary(zip(exact.map(\.id), whole), uniquingKeysWith: { first, _ in first })
    }

    public func accounts(in barID: String, where matches: (AccountCell) -> Bool) -> [String] {
        columns.filter { $0.status != .disabled && matches($0.cell(barID)) }.map(\.name)
    }

    public func accountsWithoutData(in barID: String) -> [String] {
        accounts(in: barID) { $0.value == .unknown }
    }

    public var accountsNeedingSignIn: [String] {
        columns.filter { $0.status == .needsSignIn }.map(\.name)
    }

    private static func blockedWithoutEnd(_ columns: [AccountColumn]) -> Comeback? {
        let signIn = columns.filter { $0.status == .needsSignIn }.map(\.name)
        if !signIn.isEmpty {
            return Comeback(kind: .needsSignIn, at: nil, accounts: signIn, gains: [])
        }
        let open = columns.filter { $0.status == .blocked(until: nil) }.map(\.name)
        return open.isEmpty ? nil : Comeback(kind: .blockedWithoutEnd, at: nil, accounts: open, gains: [])
    }
}

public extension PooledWindow {
    var accountSlots: Int { max(0, accounts) }
}

private struct ComebackTimeline {
    typealias Gainer = (label: String, cameBack: Bool, percents: [String: Double])

    struct Event {
        var at: Date
        var gains: [Gainer]

        func comebacks(barIDs: [String]) -> [Comeback] {
            let gainers = gains.filter { gain in barIDs.contains { (gain.percents[$0] ?? 0) > 0 } }
            return [
                comeback(.accountsBack, gainers.filter(\.cameBack), barIDs: barIDs),
                comeback(.windowsReset, gainers.filter { !$0.cameBack }, barIDs: barIDs)
            ].compactMap(\.self)
        }

        private func comeback(_ kind: Comeback.Kind, _ gainers: [Gainer], barIDs: [String]) -> Comeback? {
            guard !gainers.isEmpty else { return nil }
            let totals = barIDs.compactMap { barID -> Comeback.Gain? in
                let percent = gainers.compactMap { $0.percents[barID] }.reduce(0, +)
                return percent > 0 ? Comeback.Gain(barID: barID, percent: percent) : nil
            }
            return Comeback(kind: kind, at: at, accounts: gainers.map(\.label), gains: totals)
        }
    }

    let events: [Event]

    init(accounts: [AccountSummary], names: [String: String], now: Date) {
        let members = accounts.map { (label: names[$0.id] ?? $0.label, pooled: $0.poolAccount) }.filter { $0.pooled.countsTowardCapacity }
        let barIDs = Set(members.flatMap { $0.pooled.bars.map(\.id) } + [FiveHourWindowState.barID])
        let dates = Set(members.flatMap { $0.pooled.changeDates(after: now) }).sorted()
        var events: [Event] = []
        var before = now
        for at in Self.clusterEnds(dates) {
            let gains = members.compactMap { member -> Gainer? in
                var percents: [String: Double] = [:]
                for barID in barIDs {
                    let increase = (member.pooled.usablePercent(in: barID, at: at) ?? 0) - (member.pooled.usablePercent(in: barID, at: before) ?? 0)
                    if increase > 0 { percents[barID] = increase }
                }
                guard !percents.isEmpty else { return nil }
                return (member.label, !member.pooled.isUsable(at: before) && member.pooled.isUsable(at: at), percents)
            }
            if !gains.isEmpty { events.append(Event(at: at, gains: gains)) }
            before = at
        }
        self.events = events
    }

    private static func clusterEnds(_ sorted: [Date]) -> [Date] {
        var ends: [Date] = []
        var start: Date?
        for date in sorted {
            if let first = start, date.timeIntervalSince(first) <= ProviderOverview.comebackClusterSeconds {
                ends[ends.count - 1] = date
            } else {
                start = date
                ends.append(date)
            }
        }
        return ends
    }
}

public struct PoolSegment: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case counted
        case idle
        case leftOut
        case unknown
        case disabled
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var remainingPercent: Double
    public var isBlocked: Bool

    public init(id: String, name: String, kind: Kind, remainingPercent: Double = 0, isBlocked: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.remainingPercent = remainingPercent
        self.isBlocked = isBlocked
    }

    public var isStub: Bool {
        switch kind {
        case .leftOut, .unknown, .disabled: true
        case .counted, .idle: false
        }
    }
}

public struct StatusChip: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case state(CredentialState)
        case needsSignIn
    }

    public var kind: Kind
    public var count: Int

    public init(kind: Kind, count: Int) {
        self.kind = kind
        self.count = count
    }
}

public extension ProviderOverview {
    func segments(_ barID: String, order: [String] = []) -> [PoolSegment] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = columns.enumerated().sorted { lhs, rhs in
            (rank[lhs.element.id] ?? order.count + lhs.offset) < (rank[rhs.element.id] ?? order.count + rhs.offset)
        }.map(\.element)
        return ordered.map { column in
            let cell = column.cell(barID)
            let kind: PoolSegment.Kind = switch cell.value {
            case .remaining: .counted
            case .idleCountedAsFull: .idle
            case .leftOutWithoutRunningWindow: .leftOut
            case .unknown: .unknown
            case .notCounted: .disabled
            }
            return PoolSegment(id: column.id, name: column.name, kind: kind, remainingPercent: min(100, max(0, cell.remainingPercent ?? 0)), isBlocked: cell.isBlocked)
        }
    }

    var chips: [StatusChip] {
        let signIn = columns.count { $0.status == .needsSignIn }
        let signInErrors = columns.count { $0.status == .needsSignIn && $0.state == .error }
        var chips = stateCounts.compactMap { count -> StatusChip? in
            let value = count.state == .error ? count.count - signInErrors : count.count
            return value > 0 ? StatusChip(kind: .state(count.state), count: value) : nil
        }
        if signIn > 0 { chips.append(StatusChip(kind: .needsSignIn, count: signIn)) }
        return chips
    }
}
