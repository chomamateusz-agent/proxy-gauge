import Foundation

public struct ModelCooldown: Sendable, Equatable, Hashable {
    public var model: String
    public var until: Date?

    public init(model: String, until: Date?) {
        self.model = model
        self.until = until
    }
}

public struct ProviderCheck: Sendable, Equatable {
    public var observedAt: Date
    public var plan: String?
    public var planActiveUntil: Date?
    public var credits: ProviderCredits?
    public var extraUsage: ExtraUsage?
    public var resets: ManualResets?
    public var note: ActiveQuotaNote?
    private var sampledTimes: [ActiveQuotaField: Date]

    public init(_ quota: ActiveQuota) {
        observedAt = quota.observedAt
        plan = quota.plan
        planActiveUntil = quota.planActiveUntil
        credits = quota.credits
        extraUsage = quota.extraUsage
        resets = quota.resets
        note = quota.note
        sampledTimes = Dictionary(uniqueKeysWithValues: ActiveQuotaField.allCases.map { ($0, quota.sampledAt(for: $0)) })
    }

    public func sampledAt(for field: ActiveQuotaField) -> Date {
        sampledTimes[field] ?? observedAt
    }
}

public struct AccountSummary: Sendable, Equatable, Identifiable {
    public var id: String
    public var provider: String
    public var label: String
    public var state: CredentialState
    public var plan: String?
    public var bars: [QuotaBar]
    public var blockedUntil: Date?
    public var availability: PoolAccount.Availability
    public var statusMessage: String?
    public var requiresSignIn: Bool
    public var creditsBalance: Double?
    public var modelCooldowns: [ModelCooldown]
    public var providerCheck: ProviderCheck?
    public var providerCheckState: ActiveRefreshState?
    public var accountsLoadedAt: Date?
    private var passivePlan: String?
    public var priority = 0
    public var endsAt: Date?
    public var hasEnded = false
    public var cooldownReason: String?

    public init(
        id: String,
        provider: String,
        label: String,
        state: CredentialState,
        plan: String? = nil,
        bars: [QuotaBar],
        blockedUntil: Date? = nil,
        availability: PoolAccount.Availability? = nil,
        statusMessage: String? = nil,
        requiresSignIn: Bool = false,
        creditsBalance: Double? = nil,
        modelCooldowns: [ModelCooldown] = [],
        providerCheck: ProviderCheck? = nil
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.state = state
        self.plan = plan
        passivePlan = plan
        self.bars = bars.sortedForDisplay()
        self.blockedUntil = blockedUntil
        self.availability = availability ?? PoolAccount.Availability(
            state: state,
            requiresSignIn: requiresSignIn,
            credentialCooldownEnds: state == .cooldown ? [blockedUntil] : []
        )
        self.statusMessage = statusMessage
        self.requiresSignIn = requiresSignIn
        self.creditsBalance = creditsBalance
        self.modelCooldowns = modelCooldowns.sorted { ($0.until ?? .distantFuture, $0.model) < ($1.until ?? .distantFuture, $1.model) }
        self.providerCheck = providerCheck
    }

    public init(credential: Credential, active: ActiveQuota? = nil, now: Date) {
        let message = credential.statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let passivePlan = SignalQuotaParser.plan(provider: credential.provider, observations: credential.observations)
        self.init(
            id: credential.id,
            provider: credential.provider,
            label: credential.displayName,
            state: credential.state(at: now),
            plan: QuotaMerge.plan(passive: passivePlan, active: active),
            bars: QuotaMerge.bars(passive: credential.quotaBars, active: active),
            blockedUntil: credential.activeCredentialCooldown(at: now)?.retryAt,
            availability: PoolAccount(credential: credential, active: active, now: now).availability,
            statusMessage: message?.isEmpty == false ? message : nil,
            requiresSignIn: credential.requiresSignIn,
            creditsBalance: active?.credits.flatMap { $0.currency == nil ? $0.balance : nil },
            modelCooldowns: credential.activeCooldowns(at: now).filter { !$0.isCredentialWide }.map {
                ModelCooldown(model: $0.modelKey ?? "", until: $0.retryAt)
            },
            providerCheck: active.map(ProviderCheck.init)
        )
        self.passivePlan = passivePlan
        priority = credential.priority ?? 0
        endsAt = credential.endsAt
        hasEnded = credential.hasEnded
        cooldownReason = credential.activeCredentialCooldown(at: now)?.reason
    }

    public init(fleet credential: FleetCredential, now: Date) {
        let active = credential.cooldowns.filter { $0.until.map { $0 > now } ?? true }
        let credentialWide = active.filter { $0.scope != "model" }
        self.init(
            id: credential.id,
            provider: credential.provider,
            label: credential.label,
            state: credential.credentialState,
            plan: credential.plan,
            bars: credential.bars.map(\.quotaBar),
            blockedUntil: credentialWide.contains { $0.until == nil } ? nil : credentialWide.compactMap(\.until).max(),
            availability: PoolAccount(fleet: credential).availability,
            creditsBalance: credential.credits?.balance,
            modelCooldowns: active.filter { $0.scope == "model" }.map { ModelCooldown(model: $0.model ?? "", until: $0.until) }
        )
        cooldownReason = credentialWide.first?.reason
    }

    public static func board(_ accounts: [AccountSummary]) -> [AccountSummary] {
        accounts.sorted { lhs, rhs in
            let left = ProviderCatalog.sortKey(lhs.provider), right = ProviderCatalog.sortKey(rhs.provider)
            return left == right ? lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending : left < right
        }
    }

    public static func windowIDs(_ accounts: [AccountSummary]) -> [String] {
        var seen = Set<String>()
        return accounts.flatMap(\.bars).sortedForDisplay().map(\.id).filter { seen.insert($0).inserted }
    }

    public func bar(_ id: String) -> QuotaBar? {
        bars.first { $0.id == id }
    }

    public func block(for barID: String? = nil, at now: Date) -> PoolAccount.Block? {
        poolAccount.block(for: barID, at: now)
    }

    var poolAccount: PoolAccount {
        PoolAccount(provider: provider, availability: availability, bars: bars)
    }

    public var cardPlan: String? {
        isCurrentProviderFact(.plan) ? plan : passivePlan
    }

    public var cardPaidUntil: Date? {
        isCurrentProviderFact(.planActiveUntil) ? providerCheck?.planActiveUntil : nil
    }

    public var cardExtraUsage: ExtraUsage? {
        isCurrentProviderFact(.extraUsage) ? providerCheck?.extraUsage : nil
    }

    public func cardResets(at now: Date) -> ManualResets? {
        guard isCurrentProviderFact(.resets), let resets = providerCheck?.resets?.usable(at: now), resets.remaining > 0 else { return nil }
        return resets
    }

    public func isCurrentProviderFact(_ field: ActiveQuotaField) -> Bool {
        guard let providerCheck else { return true }
        return accountsLoadedAt.map { providerCheck.sampledAt(for: field) >= $0 } ?? true
    }

    public func fiveHourWindow(at now: Date) -> FiveHourWindowState {
        FiveHourWindowState(provider: provider, bars: bars, now: now)
    }
}
