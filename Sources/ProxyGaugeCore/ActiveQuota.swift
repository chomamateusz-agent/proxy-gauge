import Foundation

public struct ManualResets: Codable, Sendable, Equatable, Hashable {
    public var remaining: Int
    public var total: Int?
    public var expiresAt: Date?

    public init(remaining: Int, total: Int? = nil, expiresAt: Date? = nil) {
        self.remaining = remaining
        self.total = total
        self.expiresAt = expiresAt
    }

    public var everHadResets: Bool {
        remaining > 0 || (total ?? 0) > 0
    }
}

public struct ExtraUsage: Codable, Sendable, Equatable, Hashable {
    public var isEnabled: Bool?
    public var used: Double?
    public var limit: Double?
    public var currency: String?

    public init(isEnabled: Bool? = nil, used: Double? = nil, limit: Double? = nil, currency: String? = nil) {
        self.isEnabled = isEnabled
        self.used = used
        self.limit = limit
        self.currency = currency
    }
}

public struct ProviderCredits: Codable, Sendable, Equatable, Hashable {
    public var balance: Double?
    public var unlimited: Bool
    public var currency: String?

    public init(balance: Double?, unlimited: Bool = false, currency: String? = nil) {
        self.balance = balance
        self.unlimited = unlimited
        self.currency = currency
    }
}

public enum ActiveQuotaNote: String, Codable, Sendable, Equatable, Hashable {
    case paidKeyAnswered
    case limitReached
}

public struct ActiveQuota: Codable, Sendable, Equatable, Hashable {
    public var credentialID: String
    public var provider: String
    public var observedAt: Date
    public var windows: [QuotaBar]
    public var plan: String?
    public var planActiveUntil: Date?
    public var credits: ProviderCredits?
    public var extraUsage: ExtraUsage?
    public var resets: ManualResets?
    public var note: ActiveQuotaNote?

    public init(
        credentialID: String,
        provider: String,
        observedAt: Date,
        windows: [QuotaBar] = [],
        plan: String? = nil,
        planActiveUntil: Date? = nil,
        credits: ProviderCredits? = nil,
        extraUsage: ExtraUsage? = nil,
        resets: ManualResets? = nil,
        note: ActiveQuotaNote? = nil
    ) {
        self.credentialID = credentialID
        self.provider = provider
        self.observedAt = observedAt
        self.windows = windows
        self.plan = plan
        self.planActiveUntil = planActiveUntil
        self.credits = credits
        self.extraUsage = extraUsage
        self.resets = resets
        self.note = note
    }

    public var hasData: Bool {
        !windows.isEmpty || plan != nil || credits != nil || extraUsage != nil || resets != nil || note != nil
    }

    public func superseding(_ previous: ActiveQuota?, read fields: Set<ActiveQuotaField>) -> ActiveQuota {
        guard let previous, previous.credentialID == credentialID else { return self }
        var merged = self
        if !fields.contains(.windows) { merged.windows = previous.windows }
        if !fields.contains(.plan) { merged.plan = previous.plan }
        if !fields.contains(.planActiveUntil) { merged.planActiveUntil = previous.planActiveUntil }
        if !fields.contains(.credits) { merged.credits = previous.credits }
        if !fields.contains(.extraUsage) { merged.extraUsage = previous.extraUsage }
        if !fields.contains(.resets) { merged.resets = previous.resets }
        if !fields.contains(.note) { merged.note = previous.note }
        return merged
    }
}

public enum ActiveQuotaField: Sendable, Hashable, CaseIterable {
    case windows
    case plan
    case planActiveUntil
    case credits
    case extraUsage
    case resets
    case note
}

public enum QuotaMerge {
    public static func bars(passive: [QuotaBar], active: ActiveQuota?) -> [QuotaBar] {
        guard let active, !active.windows.isEmpty else { return passive }
        var byID: [String: QuotaBar] = [:]
        for bar in passive {
            byID[bar.id] = bar
        }
        for bar in active.windows {
            guard let current = byID[bar.id] else {
                byID[bar.id] = bar
                continue
            }
            if (bar.sampledAt ?? .distantPast) >= (current.sampledAt ?? .distantPast) {
                byID[bar.id] = bar
            }
        }
        return Array(byID.values).sortedForDisplay()
    }

    public static func plan(passive: String?, active: ActiveQuota?) -> String? {
        active?.plan ?? passive
    }
}
