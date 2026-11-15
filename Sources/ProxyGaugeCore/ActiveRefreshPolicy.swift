import Foundation

public enum ActiveRequestKind: String, Codable, Sendable, CaseIterable, Hashable {
    case usage
    case profile
    case resetGrants
    case subscription
    case resetCredits
    case quotaSummary
    case plan
    case userStatus
    case billing
    case paidKeyCheck
}

public enum KimiDomain: String, Sendable, Equatable {
    case com
    case ai
}

public struct ActiveTarget: Sendable, Equatable, Identifiable {
    public var credentialID: String
    public var authIndex: String?
    public var provider: String
    public var label: String
    public var fileName: String
    public var disabled: Bool
    public var accountID: String?
    public var projectID: String?

    public var id: String { credentialID }

    public init(
        credentialID: String,
        authIndex: String?,
        provider: String,
        label: String,
        fileName: String = "",
        disabled: Bool = false,
        accountID: String? = nil,
        projectID: String? = nil
    ) {
        self.credentialID = credentialID
        self.authIndex = authIndex
        self.provider = provider.lowercased()
        self.label = label
        self.fileName = fileName
        self.disabled = disabled
        self.accountID = accountID
        self.projectID = projectID
    }

    public init(credential: Credential, now: Date) {
        self.init(
            credentialID: credential.stableID,
            authIndex: credential.authIndex,
            provider: credential.provider,
            label: credential.displayName,
            fileName: credential.name,
            disabled: credential.state(at: now) == .disabled,
            accountID: credential.chatgptAccountID,
            projectID: credential.projectID
        )
    }

    public var kimiDomain: KimiDomain {
        let text = (provider + " " + fileName).lowercased()
        return text.contains("kimi-ai") || text.contains("kimi.ai") ? .ai : .com
    }
}

public struct ActiveScope: Sendable, Equatable {
    public var includesProfile: Bool
    public var includesResetInventory: Bool
    public var allowsPaidKeyCheck: Bool

    public init(includesProfile: Bool, includesResetInventory: Bool, allowsPaidKeyCheck: Bool) {
        self.includesProfile = includesProfile
        self.includesResetInventory = includesResetInventory
        self.allowsPaidKeyCheck = allowsPaidKeyCheck
    }

    public static let manual = ActiveScope(includesProfile: true, includesResetInventory: true, allowsPaidKeyCheck: true)

    public static func automatic(includesProfile: Bool) -> ActiveScope {
        ActiveScope(includesProfile: includesProfile, includesResetInventory: false, allowsPaidKeyCheck: false)
    }
}

public enum ActiveRefreshOrigin: Sendable, Equatable {
    case visibleApp
    case menuBar
    case widget
    case background
}

public enum ActiveRefreshMode: Sendable, Equatable {
    case manual
    case automatic(interval: TimeInterval, origin: ActiveRefreshOrigin)
}

public enum ActiveRefreshFailure: Codable, Sendable, Equatable, Hashable {
    case rateLimited
    case rejected(status: Int)
    case upstream(status: Int)
    case unreadable
    case management
    case refusedByProxy(ProxyAccountRefusal)
}

public enum ProxyAccountRefusal: String, Codable, Sendable, Equatable, Hashable {
    case signInRefreshFailed
    case accountNotFound
    case signInMissing
    case requestRejected

    init(message: String?) {
        switch message {
        case "auth token refresh failed": self = .signInRefreshFailed
        case "auth credential not found for auth_index": self = .accountNotFound
        case "auth token not found": self = .signInMissing
        default: self = .requestRejected
        }
    }
}

public struct ActiveRefreshState: Codable, Sendable, Equatable {
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var nextAllowedAt: Date?
    public var jitter: Double
    public var profileCheckedAt: Date?
    public var consecutiveRateLimits: Int
    public var rateLimitedUntil: Date?
    public var automaticSuspended: Bool
    public var rejectedStatus: Int?
    public var lastFailure: ActiveRefreshFailure?

    public init() {
        jitter = 0
        consecutiveRateLimits = 0
        automaticSuspended = false
    }

    public static func assumingAttempt(at now: Date) -> ActiveRefreshState {
        var state = ActiveRefreshState()
        state.recordAttempt(now: now, jitter: ActiveRefreshPolicy.maximumJitter)
        return state
    }

    enum CodingKeys: String, CodingKey {
        case lastAttemptAt, lastSuccessAt, nextAllowedAt, jitter, profileCheckedAt
        case consecutiveRateLimits, rateLimitedUntil, automaticSuspended, rejectedStatus, lastFailure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        nextAllowedAt = try container.decodeIfPresent(Date.self, forKey: .nextAllowedAt)
        jitter = try container.decodeIfPresent(Double.self, forKey: .jitter) ?? 0
        profileCheckedAt = try container.decodeIfPresent(Date.self, forKey: .profileCheckedAt)
        consecutiveRateLimits = try container.decodeIfPresent(Int.self, forKey: .consecutiveRateLimits) ?? 0
        rateLimitedUntil = try container.decodeIfPresent(Date.self, forKey: .rateLimitedUntil)
        automaticSuspended = try container.decodeIfPresent(Bool.self, forKey: .automaticSuspended) ?? false
        rejectedStatus = try container.decodeIfPresent(Int.self, forKey: .rejectedStatus)
        lastFailure = (try? container.decodeIfPresent(ActiveRefreshFailure.self, forKey: .lastFailure)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(lastAttemptAt.map(Self.wholeSecondAtOrAfter), forKey: .lastAttemptAt)
        try container.encodeIfPresent(lastSuccessAt.map(Self.wholeSecondAtOrAfter), forKey: .lastSuccessAt)
        try container.encodeIfPresent(nextAllowedAt.map(Self.wholeSecondAtOrAfter), forKey: .nextAllowedAt)
        try container.encode(jitter, forKey: .jitter)
        try container.encodeIfPresent(profileCheckedAt.map(Self.wholeSecondAtOrAfter), forKey: .profileCheckedAt)
        try container.encode(consecutiveRateLimits, forKey: .consecutiveRateLimits)
        try container.encodeIfPresent(rateLimitedUntil.map(Self.wholeSecondAtOrAfter), forKey: .rateLimitedUntil)
        try container.encode(automaticSuspended, forKey: .automaticSuspended)
        try container.encodeIfPresent(rejectedStatus, forKey: .rejectedStatus)
        try container.encodeIfPresent(lastFailure, forKey: .lastFailure)
    }

    static func wholeSecondAtOrAfter(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.up))
    }

    public func cappingWaits(at now: Date) -> ActiveRefreshState {
        let latest = now.addingTimeInterval(ActiveRefreshPolicy.longestWait)
        var capped = self
        capped.nextAllowedAt = nextAllowedAt.map { min($0, latest) }
        capped.rateLimitedUntil = rateLimitedUntil.map { min($0, latest) }
        return capped
    }

    public func isRateLimited(at now: Date) -> Bool {
        rateLimitedUntil.map { $0 > now } ?? false
    }

    public func automaticDue(provider: String, interval: TimeInterval) -> Date? {
        lastAttemptAt.map { $0.addingTimeInterval(ActiveRefreshPolicy.automaticInterval(provider: provider, chosen: interval) * (1 + jitter)) }
    }

    mutating func recordAttempt(now: Date, jitter: Double) {
        lastAttemptAt = now
        self.jitter = jitter
        let earliest = now.addingTimeInterval(ActiveRefreshPolicy.manualMinimum * (1 + jitter))
        nextAllowedAt = max(nextAllowedAt ?? earliest, earliest)
    }

    mutating func recordSuccess(now: Date, checkedProfile: Bool) {
        lastSuccessAt = now
        if checkedProfile { profileCheckedAt = now }
        consecutiveRateLimits = 0
        rateLimitedUntil = nil
        automaticSuspended = false
        rejectedStatus = nil
        lastFailure = nil
        nextAllowedAt = now.addingTimeInterval(ActiveRefreshPolicy.manualMinimum * (1 + jitter))
    }

    mutating func recordRateLimit(provider: String, retryAfter: Date?, now: Date) {
        consecutiveRateLimits += 1
        let wait = ActiveRefreshPolicy.rateLimitWait(provider: provider, consecutive: consecutiveRateLimits, retryAfter: retryAfter, now: now)
        let until = now.addingTimeInterval(min(wait * (1 + jitter), ActiveRefreshPolicy.longestWait))
        rateLimitedUntil = until
        nextAllowedAt = until
        if consecutiveRateLimits >= ActiveRefreshPolicy.rateLimitsBeforeSuspending {
            automaticSuspended = true
        }
        lastFailure = .rateLimited
    }

    mutating func recordRejected(status: Int) {
        rejectedStatus = status
        lastFailure = .rejected(status: status)
    }

    mutating func recordFailure(_ failure: ActiveRefreshFailure) {
        lastFailure = failure
    }

    public var lastFailureNote: ProviderCheckFailureNote? {
        switch lastFailure {
        case .upstream(let status): .upstream(status: status)
        case .unreadable: .unreadable
        case .refusedByProxy(let refusal): .refusedByProxy(refusal)
        case .rateLimited, .rejected, .management, nil: nil
        }
    }
}

public enum ProviderCheckFailureNote: Sendable, Equatable {
    case upstream(status: Int)
    case unreadable
    case refusedByProxy(ProxyAccountRefusal)
}

public enum ActiveRefreshSkip: Sendable, Equatable {
    case unsupported
    case disabled
    case missingAuthIndex
    case missingProject
    case notVisible
    case excludedFromAutomatic
    case automaticSuspended
    case rejectedByProvider
}

public enum ActiveRefreshWait: Sendable, Equatable {
    case rateLimited
    case recentlyChecked
    case proxyRefused
}

public struct ProxyRefusalBackoff: Codable, Sendable, Equatable {
    public var consecutiveRefusals: Int
    public var until: Date

    public init(consecutiveRefusals: Int, until: Date) {
        self.consecutiveRefusals = consecutiveRefusals
        self.until = until
    }

    public static func after(_ previous: ProxyRefusalBackoff?, now: Date) -> ProxyRefusalBackoff {
        let refusals = (previous?.consecutiveRefusals ?? 0) + 1
        let wait = min(ActiveRefreshPolicy.proxyRefusalBase * pow(2, Double(refusals - 1)), ActiveRefreshPolicy.backoffCap)
        return ProxyRefusalBackoff(consecutiveRefusals: refusals, until: ActiveRefreshState.wholeSecondAtOrAfter(now.addingTimeInterval(wait)))
    }

    public func capped(at now: Date) -> ProxyRefusalBackoff {
        var capped = self
        capped.until = min(until, ActiveRefreshState.wholeSecondAtOrAfter(now.addingTimeInterval(ActiveRefreshPolicy.backoffCap)))
        return capped
    }

    public func automaticChecksResume(after now: Date) -> Date? {
        until > now ? until : nil
    }
}

public enum ActiveRefreshDecision: Sendable, Equatable {
    case run(ActiveScope)
    case wait(until: Date, because: ActiveRefreshWait)
    case skip(ActiveRefreshSkip)
}

public enum ActiveRefreshPolicy {
    public static let manualMinimum: TimeInterval = 5 * 60
    public static let automaticIntervalChoices: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60]
    public static let defaultAutomaticInterval: TimeInterval = 30 * 60
    public static let claudeAutomaticMinimum: TimeInterval = 30 * 60
    public static let profileLifetime: TimeInterval = 24 * 3_600
    public static let backoffCap: TimeInterval = 6 * 3_600
    public static let proxyRefusalBase: TimeInterval = 15 * 60
    public static let longestWait: TimeInterval = 7 * 86_400
    public static let rateLimitsBeforeSuspending = 3
    public static let maximumJitter = 0.2

    private static let supportedProviders: Set<String> = ["claude", "codex", "antigravity", "kimi", "devin", "xai"]
    private static let automaticProviders: Set<String> = ["claude", "codex", "kimi", "devin"]
    private static let googleProviders: Set<String> = ["antigravity", "gemini-cli", "gemini"]

    public static func isSupported(_ provider: String) -> Bool {
        supportedProviders.contains(provider.lowercased())
    }

    public static func refreshesAutomatically(_ provider: String) -> Bool {
        automaticProviders.contains(provider.lowercased())
    }

    public static func usesUnofficialGoogleEndpoints(_ provider: String) -> Bool {
        googleProviders.contains(provider.lowercased())
    }

    public static func mayRunPaidCompletion(_ provider: String) -> Bool {
        provider.lowercased() == "xai"
    }

    public static func automaticInterval(provider: String, chosen: TimeInterval) -> TimeInterval {
        let floor = provider.lowercased() == "claude" ? claudeAutomaticMinimum : automaticIntervalChoices[0]
        return max(chosen, floor)
    }

    public static func backoffBase(provider: String) -> TimeInterval {
        provider.lowercased() == "claude" ? 30 * 60 : 15 * 60
    }

    public static func rateLimitWait(provider: String, consecutive: Int, retryAfter: Date?, now: Date) -> TimeInterval {
        let doublings = Double(max(0, consecutive - 1))
        let policy = min(backoffBase(provider: provider) * pow(2, doublings), backoffCap)
        let requested = retryAfter.map { $0.timeIntervalSince(now) } ?? 0
        return min(max(policy, requested), longestWait)
    }

    public static func decide(_ target: ActiveTarget, state: ActiveRefreshState, mode: ActiveRefreshMode, hasReading: Bool = true, now: Date) -> ActiveRefreshDecision {
        guard isSupported(target.provider) else { return .skip(.unsupported) }
        guard !target.disabled else { return .skip(.disabled) }
        guard target.authIndex?.isEmpty == false else { return .skip(.missingAuthIndex) }
        guard target.provider != "antigravity" || target.projectID?.isEmpty == false else { return .skip(.missingProject) }
        switch mode {
        case .manual:
            if let wait = waitForAllowance(state, now: now), !mayCheckOnceWithoutReading(state, hasReading: hasReading, now: now) { return wait }
            return .run(.manual)
        case .automatic(let interval, let origin):
            guard origin == .visibleApp else { return .skip(.notVisible) }
            guard refreshesAutomatically(target.provider) else { return .skip(.excludedFromAutomatic) }
            guard state.rejectedStatus == nil else { return .skip(.rejectedByProvider) }
            guard !state.automaticSuspended else { return .skip(.automaticSuspended) }
            if let wait = waitForAllowance(state, now: now) { return wait }
            if let due = state.automaticDue(provider: target.provider, interval: interval), due > now {
                return .wait(until: due, because: .recentlyChecked)
            }
            let profileIsStale = state.profileCheckedAt.map { now.timeIntervalSince($0) >= profileLifetime } ?? true
            return .run(.automatic(includesProfile: profileIsStale))
        }
    }

    private static func mayCheckOnceWithoutReading(_ state: ActiveRefreshState, hasReading: Bool, now: Date) -> Bool {
        guard !hasReading, !state.isRateLimited(at: now) else { return false }
        return state.lastAttemptAt.map { now.timeIntervalSince($0) >= manualMinimum } ?? true
    }

    private static func waitForAllowance(_ state: ActiveRefreshState, now: Date) -> ActiveRefreshDecision? {
        guard let until = state.nextAllowedAt, until > now else { return nil }
        return .wait(until: until, because: state.isRateLimited(at: now) ? .rateLimited : .recentlyChecked)
    }
}
