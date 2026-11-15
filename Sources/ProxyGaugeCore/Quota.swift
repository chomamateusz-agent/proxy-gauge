import Foundation

public enum QuotaSource: String, Codable, Sendable, Hashable {
    case proxy
    case provider
}

public struct QuotaBar: Codable, Sendable, Equatable, Identifiable, Hashable {
    public static let rejectedStatus = "rejected"

    public var id: String
    public var usedPercent: Double?
    public var status: String?
    public var resetsAt: Date?
    public var sampledAt: Date?
    public var label: String?
    public var source: QuotaSource?

    public init(id: String, usedPercent: Double?, status: String? = nil, resetsAt: Date? = nil, sampledAt: Date? = nil, label: String? = nil, source: QuotaSource? = nil) {
        self.id = id
        self.usedPercent = usedPercent
        self.status = status
        self.resetsAt = resetsAt
        self.sampledAt = sampledAt
        self.label = label
        self.source = source
    }

    public var isFromProvider: Bool { source == .provider }

    public var headroomPercent: Double? {
        usedPercent.map { max(0, min(100, 100 - $0)) }
    }

    public var window: QuotaWindow { QuotaWindow(barID: id) }

    public func hasReset(at now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    public func effectiveUsedPercent(at now: Date) -> Double? {
        remainingPercent(at: now).map { 100 - $0 }
    }

    public func remainingPercent(at now: Date) -> Double? {
        if hasReset(at: now) { return 100 }
        if isAtLimit(at: now) { return 0 }
        return headroomPercent
    }

    public func isAtLimit(at now: Date) -> Bool {
        guard !hasReset(at: now) else { return false }
        return status == Self.rejectedStatus || (usedPercent ?? 0) >= 100
    }

    public func startsOnUse(provider: String, at now: Date) -> Bool {
        id == FiveHourWindowState.barID
            && ProviderCatalog.reportsFiveHourWindow(provider)
            && usedPercent == 0
            && resetsAt == nil
            && !isAtLimit(at: now)
    }
}

public enum FiveHourWindowState: Equatable, Sendable {
    case notTracked
    case neverSampled
    case notReported
    case startsOnUse
    case running

    public static let barID = "session_5h"

    public init(provider: String, bars: [QuotaBar], now: Date) {
        if let session = bars.first(where: { $0.id == Self.barID }) {
            self = session.startsOnUse(provider: provider, at: now) ? .startsOnUse : .running
        } else if !ProviderCatalog.reportsFiveHourWindow(provider) {
            self = .notTracked
        } else {
            self = bars.isEmpty ? .neverSampled : .notReported
        }
    }
}

public enum QuotaWindow: Equatable, Sendable, Hashable {
    case session5h
    case weekly
    case weeklyModel
    case daily
    case monthly
    case minutes(Int)
    case other(String)

    public init(barID: String) {
        switch barID {
        case "session_5h": self = .session5h
        case "weekly_all": self = .weekly
        case "weekly_fable": self = .weeklyModel
        case "daily": self = .daily
        case "monthly": self = .monthly
        default:
            if let match = barID.wholeMatch(of: /window_(\d+)m/), let minutes = Int(match.1) {
                self = .minutes(minutes)
            } else {
                self = .other(barID)
            }
        }
    }

    public var sortOrder: Int {
        switch self {
        case .session5h: 0
        case .daily: 1
        case .weekly: 2
        case .weeklyModel: 3
        case .monthly: 4
        case .minutes: 5
        case .other: 6
        }
    }
}

public extension Array where Element == QuotaBar {
    func sortedForDisplay() -> [QuotaBar] {
        sorted { lhs, rhs in
            lhs.window.sortOrder == rhs.window.sortOrder ? lhs.id < rhs.id : lhs.window.sortOrder < rhs.window.sortOrder
        }
    }
}

public enum CredentialState: String, Codable, Sendable, CaseIterable, Hashable {
    case active
    case cooldown
    case disabled
    case error

    public init(wireValue: String) {
        self = CredentialState(rawValue: wireValue.lowercased()) ?? .active
    }

    public init(credential: Credential, now: Date) {
        if credential.disabled || credential.status?.lowercased() == "disabled" {
            self = .disabled
        } else if credential.activeCredentialCooldown(at: now) != nil {
            self = .cooldown
        } else if credential.status?.lowercased() == "error" || credential.requiresSignIn {
            self = .error
        } else {
            self = .active
        }
    }
}

public extension Credential {
    func activeCooldowns(at now: Date) -> [Cooldown] {
        (cooldowns ?? []).filter { $0.isActive(at: now) }
    }

    func activeCredentialCooldown(at now: Date) -> Cooldown? {
        activeCooldowns(at: now).filter(\.isCredentialWide).max { ($0.retryAt ?? .distantFuture) < ($1.retryAt ?? .distantFuture) }
    }

    func state(at now: Date) -> CredentialState {
        CredentialState(credential: self, now: now)
    }

    var quotaBars: [QuotaBar] {
        SignalQuotaParser.bars(provider: provider, observations: observations)
    }
}

public enum SignalQuotaParser {
    public static func bars(provider: String, observations: [QuotaObservation]) -> [QuotaBar] {
        switch provider.lowercased() {
        case "claude": claudeBars(observations)
        case "codex": codexBars(observations)
        case "devin": devinBars(observations)
        default: []
        }
    }

    public static func plan(provider: String, observations: [QuotaObservation]) -> String? {
        guard provider.lowercased() == "codex",
              let observation = freshest(observations, carrying: ["X-Codex-Plan-Type"]),
              let plan = observation.signal("X-Codex-Plan-Type")?.trimmingCharacters(in: .whitespaces),
              !plan.isEmpty
        else { return nil }
        return plan.lowercased()
    }

    private static func freshest(_ observations: [QuotaObservation], carrying names: [String]) -> QuotaObservation? {
        observations
            .filter { observation in names.contains { !(observation.signal($0)?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) } }
            .max { ($0.observedAt ?? .distantPast) < ($1.observedAt ?? .distantPast) }
    }

    private static func claudeBars(_ observations: [QuotaObservation]) -> [QuotaBar] {
        let windows = [
            ("weekly_all", "Anthropic-Ratelimit-Unified-7d-"),
            ("weekly_fable", "Anthropic-Ratelimit-Unified-7d_oi-"),
            ("session_5h", "Anthropic-Ratelimit-Unified-5h-")
        ]
        return windows.compactMap { id, prefix in
            let utilisation = prefix + "Utilization", status = prefix + "Status", reset = prefix + "Reset"
            guard let observation = freshest(observations, carrying: [utilisation, status, reset]) else { return nil }
            return QuotaBar(
                id: id,
                usedPercent: number(observation.signal(utilisation)).map { rounded($0 * 100) },
                status: barStatus(observation.signal(status)),
                resetsAt: resetDate(observation.signal(reset)),
                sampledAt: observation.observedAt,
                source: .proxy
            )
        }
    }

    private static func codexBars(_ observations: [QuotaObservation]) -> [QuotaBar] {
        var seen = Set<String>()
        var bars: [QuotaBar] = []
        for prefix in ["X-Codex-Primary-", "X-Codex-Secondary-"] {
            guard let observation = freshest(observations, carrying: [prefix + "Used-Percent"]),
                  let minutes = number(observation.signal(prefix + "Window-Minutes")),
                  minutes >= 1, minutes < Double(Int32.max)
            else { continue }
            let id = codexBarID(minutes: Int(minutes))
            guard seen.insert(id).inserted else { continue }
            var resetsAt = resetDate(observation.signal(prefix + "Reset-At"))
            if resetsAt == nil, let after = number(observation.signal(prefix + "Reset-After-Seconds")), let observedAt = observation.observedAt {
                resetsAt = observedAt.addingTimeInterval(after)
            }
            bars.append(QuotaBar(
                id: id,
                usedPercent: number(observation.signal(prefix + "Used-Percent")).map(rounded),
                resetsAt: resetsAt,
                sampledAt: observation.observedAt,
                source: .proxy
            ))
        }
        return bars
    }

    private static func devinBars(_ observations: [QuotaObservation]) -> [QuotaBar] {
        [("daily", "daily_quota_remaining_percent"), ("weekly_all", "weekly_quota_remaining_percent")].compactMap { id, key in
            guard let observation = freshest(observations, carrying: [key]),
                  let raw = observation.signal(key)?.replacingOccurrences(of: "%", with: ""),
                  let remaining = number(raw)
            else { return nil }
            return QuotaBar(id: id, usedPercent: rounded(100 - remaining), sampledAt: observation.observedAt, source: .proxy)
        }
    }

    public static func codexBarID(minutes: Int) -> String {
        switch minutes {
        case 7 * 24 * 60: "weekly_all"
        case 5 * 60: "session_5h"
        default: "window_\(minutes)m"
        }
    }

    private static func barStatus(_ raw: String?) -> String? {
        let status = raw?.trimmingCharacters(in: .whitespaces).lowercased()
        return ["allowed", "allowed_warning", "rejected"].contains(status) ? status : nil
    }

    private static func number(_ raw: String?) -> Double? {
        guard let raw, let value = Double(raw.trimmingCharacters(in: .whitespaces)), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    public static func resetDate(_ raw: String?) -> Date? {
        guard let text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = Double(text), seconds > 0, seconds.isFinite {
            return Date(timeIntervalSince1970: seconds)
        }
        return WireDate.parse(text)
    }
}
