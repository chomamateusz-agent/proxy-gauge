import Foundation

public enum CardSection: Int, Sendable, Equatable, Comparable, CaseIterable {
    case usable
    case comingBack
    case needsAttention

    public static func < (lhs: CardSection, rhs: CardSection) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum RouterBadge: Sendable, Equatable, Hashable {
    case ranked(position: Int, tier: RouterTier)
    case noReading
    case coolingDown
    case disabled
    case ended
    case listOrder
}

public enum CardOrderMode: Sendable, Equatable {
    case stock
    case router(RouterSettings)
}

public struct OrderedAccount: Sendable, Equatable, Identifiable {
    public var account: AccountSummary
    public var section: CardSection
    public var badge: RouterBadge?

    public var id: String { account.id }

    public init(account: AccountSummary, section: CardSection, badge: RouterBadge? = nil) {
        self.account = account
        self.section = section
        self.badge = badge
    }
}

public enum AccountOrder {
    public static func section(of account: AccountSummary, at now: Date) -> CardSection {
        if account.state == .disabled || account.availability == .needsSignIn { return .needsAttention }
        if account.block(at: now) != nil { return .comingBack }
        return account.state == .error ? .needsAttention : .usable
    }

    public static func ordered(_ accounts: [AccountSummary], mode: CardOrderMode, now: Date) -> [OrderedAccount] {
        switch mode {
        case .stock:
            stock(accounts, now: now)
        case .router(let settings) where settings.ranksByUseOrLose:
            router(accounts, settings: settings, now: now)
        case .router:
            accounts.map { OrderedAccount(account: $0, section: section(of: $0, at: now), badge: .listOrder) }
        }
    }

    public static func stock(_ accounts: [AccountSummary], now: Date) -> [OrderedAccount] {
        let entries = accounts.enumerated().map { offset, account in
            (offset: offset, entry: OrderedAccount(account: account, section: section(of: account, at: now)), back: account.block(at: now)?.until)
        }
        return entries.sorted { lhs, rhs in
            if lhs.entry.section != rhs.entry.section { return lhs.entry.section < rhs.entry.section }
            if lhs.entry.section == .comingBack, lhs.back != rhs.back {
                return (lhs.back ?? .distantFuture) < (rhs.back ?? .distantFuture)
            }
            return lhs.offset < rhs.offset
        }.map(\.entry)
    }

    public static func router(_ accounts: [AccountSummary], settings: RouterSettings, family: RouterFamily = .all, now: Date) -> [OrderedAccount] {
        RouterOrder.rank(accounts.map { routerCandidate($0, now: now) }, family: family, settings: settings, now: now).map { ranked in
            OrderedAccount(account: ranked.candidate.item, section: section(of: ranked.candidate.item, at: now), badge: badge(ranked.placement))
        }
    }

    public static func badge(_ placement: RouterPlacement) -> RouterBadge {
        switch placement {
        case .out(.cooling): .coolingDown
        case .out(.disabled): .disabled
        case .out(.ended): .ended
        case .ranked(_, _, _, false): .listOrder
        case .ranked(_, _, false, true): .noReading
        case .ranked(let position, let tier, _, _): .ranked(position: position, tier: tier)
        }
    }

    public static func routerCandidate(_ account: AccountSummary, now: Date) -> RouterCandidate<AccountSummary> {
        RouterCandidate(
            item: account,
            provider: account.provider,
            priority: account.priority,
            endsAt: account.endsAt,
            readings: routerReadings(account, now: now),
            outOfRotation: outOfRotation(account, now: now)
        )
    }

    public static func outOfRotation(_ account: AccountSummary, now: Date) -> RouterOutOfRotation? {
        if account.hasEnded || account.endsAt.map({ $0 <= now }) == true { return .ended }
        if account.state == .disabled { return .disabled }
        if case .blocked(let until) = account.availability, until.map({ $0 > now }) ?? true { return .cooling }
        return nil
    }

    public static func routerReadings(_ account: AccountSummary, now: Date) -> RouterReadings? {
        let windows: (weekly: QuotaBar?, fable: QuotaBar?, short: QuotaBar?)
        switch account.provider.lowercased() {
        case "claude":
            windows = (account.bar("weekly_all"), account.bar("weekly_fable") ?? account.bar("7d_oi"), account.bar(FiveHourWindowState.barID))
        case "codex":
            windows = (
                routerBar(account.bar("weekly_all"), requiring: 7 * 24 * 3_600),
                nil,
                routerBar(account.bar(FiveHourWindowState.barID), requiring: 5 * 3_600)
            )
        default:
            return nil
        }
        let present = [windows.weekly, windows.fable, windows.short].compactMap(\.self)
        guard !present.isEmpty else { return nil }
        let credits = account.providerCheck?.credits
        return RouterReadings(
            weekly: windows.weekly.map(routerWindow),
            fable: windows.fable.map(routerWindow),
            short: windows.short.map(routerWindow),
            creditsAvailable: credits?.unlimited == true || (account.creditsBalance ?? credits?.balance ?? 0) > 0,
            observedAt: present.compactMap(\.sampledAt).max() ?? now
        )
    }

    private static func routerBar(_ bar: QuotaBar?, requiring duration: TimeInterval) -> QuotaBar? {
        guard let bar, !bar.isFromProvider || bar.reportedPeriodSeconds == duration else { return nil }
        return bar
    }

    private static func routerWindow(_ bar: QuotaBar) -> RouterWindow {
        let used = bar.usedPercent ?? (bar.status == QuotaBar.rejectedStatus ? 100 : nil)
        return RouterWindow(usedPercent: used, resetsAt: bar.resetsAt)
    }
}

public struct WindowReset: Sendable, Equatable, Identifiable {
    public var barID: String
    public var label: String?
    public var resetsAt: Date?
    public var remainingPercent: Double?
    public var gainAtReset: Double?

    public var id: String { barID }
}

public extension AccountSummary {
    func resets(at now: Date) -> [WindowReset] {
        bars.map { bar in
            let remaining = bar.remainingPercent(at: now)
            let upcoming = bar.resetsAt.flatMap { $0 > now ? $0 : nil }
            let gain = upcoming != nil ? remaining.map { max(0, 100 - $0) } : nil
            return WindowReset(barID: bar.id, label: bar.label, resetsAt: bar.resetsAt, remainingPercent: remaining, gainAtReset: gain)
        }
    }

    func nextReset(after now: Date) -> Date? {
        bars.compactMap(\.resetsAt).filter { $0 > now }.min()
    }

    func comebackGains(at now: Date) -> [Comeback.Gain] {
        let pooled = poolAccount
        guard let until = pooled.block(for: nil, at: now)?.until, until > now else { return [] }
        return bars.map(\.id).compactMap { barID in
            let gain = (pooled.usablePercent(in: barID, at: until) ?? 0) - (pooled.usablePercent(in: barID, at: now) ?? 0)
            return gain > 0 ? Comeback.Gain(barID: barID, percent: gain) : nil
        }
    }

    func hasIdleFiveHourWindow(at now: Date) -> Bool {
        poolAccount.hasIdleFiveHourWindow(at: now)
    }

}
