import Foundation

public struct ManualResets: Codable, Sendable, Equatable, Hashable {
    public var remaining: Int
    public var total: Int?
    public var expiresAt: Date?
    private var supplies: [Supply]?

    struct Supply: Codable, Sendable, Equatable, Hashable {
        let count: Int
        private let startSeconds: TimeInterval?
        private let endSeconds: TimeInterval?
        let paused: Bool

        init(count: Int, startsAt: Date? = nil, endsAt: Date? = nil, paused: Bool = false) {
            self.count = count
            startSeconds = startsAt?.timeIntervalSince1970
            endSeconds = endsAt?.timeIntervalSince1970
            self.paused = paused
        }

        private var startsAt: Date? { startSeconds.map(Date.init(timeIntervalSince1970:)) }
        var endsAt: Date? { endSeconds.map(Date.init(timeIntervalSince1970:)) }

        func isUsable(at now: Date) -> Bool {
            count > 0 && !paused && (startsAt ?? .distantPast) <= now && (endsAt ?? .distantFuture) > now
        }
    }

    init(supplies: [Supply], total: Int? = nil, at now: Date) throws {
        self.init(remaining: 0, total: total)
        _ = try ProviderJSON.wholeNumber(supplies.reduce(0) { $0 + Double($1.count) })
        self.supplies = supplies
        self = usable(at: now)
    }

    public var hasUsabilityDetails: Bool { supplies != nil }

    public func usable(at now: Date) -> Self {
        var result = self
        if let supplies {
            let usable = supplies.filter { $0.isUsable(at: now) }
            result.remaining = usable.reduce(0) { $0 + $1.count }
            result.expiresAt = usable.compactMap(\.endsAt).min()
        } else if let expiresAt, expiresAt <= now {
            result.remaining = 0
            result.expiresAt = nil
        }
        return result
    }

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
    private var fieldTimes: [String: TimeInterval]?
    private var absentFiveHourSampleTime: TimeInterval?

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

    public func sampledAt(for field: ActiveQuotaField) -> Date {
        fieldTimes?[field.rawValue].map(Date.init(timeIntervalSince1970:)) ?? observedAt
    }

    var absentFiveHourSample: Date? {
        absentFiveHourSampleTime.map(Date.init(timeIntervalSince1970:))
    }

    mutating func recordReportedWindows(_ windows: [QuotaBar], at time: Date) {
        self.windows = windows
        absentFiveHourSampleTime = windows.contains { $0.id == FiveHourWindowState.barID } ? nil : time.timeIntervalSince1970
    }

    mutating func record(_ fields: Set<ActiveQuotaField>, at time: Date) {
        guard !fields.isEmpty else { return }
        if fieldTimes == nil { fieldTimes = [:] }
        for field in fields {
            fieldTimes?[field.rawValue] = time.timeIntervalSince1970
        }
    }

    public func superseding(_ previous: ActiveQuota?, read fields: Set<ActiveQuotaField>) -> ActiveQuota {
        guard let previous, previous.credentialID == credentialID else { return self }
        var merged = self
        let retained = Set(ActiveQuotaField.allCases.filter { !fields.contains($0) || sampledAt(for: $0) < previous.sampledAt(for: $0) })
        if retained.contains(.windows) {
            merged.windows = previous.windows
            merged.absentFiveHourSampleTime = previous.absentFiveHourSampleTime
        }
        if retained.contains(.plan) { merged.plan = previous.plan }
        if retained.contains(.planActiveUntil) { merged.planActiveUntil = previous.planActiveUntil }
        if retained.contains(.credits) { merged.credits = previous.credits }
        if retained.contains(.extraUsage) { merged.extraUsage = previous.extraUsage }
        if retained.contains(.resets) { merged.resets = previous.resets }
        if retained.contains(.note) { merged.note = previous.note }
        for field in retained { merged.record([field], at: previous.sampledAt(for: field)) }
        merged.observedAt = max(observedAt, previous.observedAt)
        return merged
    }
}

public enum ActiveQuotaField: String, Sendable, Hashable, CaseIterable {
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
        guard let active else { return passive }
        let fiveHourID = FiveHourWindowState.barID
        let absentFiveHourSample = active.absentFiveHourSample
        guard !active.windows.isEmpty || absentFiveHourSample != nil else { return passive }
        var byID: [String: QuotaBar] = [:]
        for bar in passive {
            if bar.id == fiveHourID, let absentFiveHourSample, (bar.sampledAt ?? .distantPast) <= absentFiveHourSample { continue }
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
