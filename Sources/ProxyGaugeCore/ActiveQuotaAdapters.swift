import Foundation
import Synchronization

final class PartialQuota: Sendable {
    private struct Readings {
        var quota: ActiveQuota
        var fields: Set<ActiveQuotaField> = []
        var profileChecked = false
    }

    private let state: Mutex<Readings>
    let credentialID: String

    init(credentialID: String, provider: String) {
        self.credentialID = credentialID
        state = Mutex(Readings(quota: ActiveQuota(credentialID: credentialID, provider: provider, observedAt: .distantPast)))
    }

    func record(_ fields: Set<ActiveQuotaField>, receivedAt: Date, _ change: (inout ActiveQuota) -> Void) {
        state.withLock { readings in
            change(&readings.quota)
            readings.fields.formUnion(fields)
            readings.quota.record(fields, at: receivedAt)
            readings.quota.observedAt = max(readings.quota.observedAt, receivedAt)
        }
    }

    func markProfileChecked() {
        state.withLock { $0.profileChecked = true }
    }

    var profileChecked: Bool { state.withLock { $0.profileChecked } }

    var hasReadings: Bool { state.withLock { !$0.fields.isEmpty } }

    func merged(onto previous: ActiveQuota?) -> ActiveQuota? {
        state.withLock { readings in
            readings.fields.isEmpty ? nil : readings.quota.superseding(previous, read: readings.fields)
        }
    }
}

struct ReceivedReply: Sendable {
    let reply: UpstreamReply
    let receivedAt: Date
}

struct ProviderAnswer {
    let object: [String: Any]
    let receivedAt: Date

    subscript(key: String) -> Any? { object[key] }

    func has(_ keys: String...) -> Bool {
        keys.contains { object.keys.contains($0) }
    }

    func bar(_ id: String, used: Double?, resetsAt: Date?, label: String? = nil, reportedPeriodSeconds: TimeInterval? = nil) -> QuotaBar {
        let clamped = used.map { max(0, ProviderJSON.rounded($0)) }
        return QuotaBar(
            id: id,
            usedPercent: clamped,
            status: clamped.map { $0 >= 100 ? QuotaBar.rejectedStatus : "allowed" },
            resetsAt: resetsAt,
            sampledAt: receivedAt,
            label: label,
            source: .provider,
            reportedPeriodSeconds: reportedPeriodSeconds
        )
    }

    func resetDate(afterSeconds value: Any?) -> Date? {
        guard let seconds = ProviderJSON.number(value), seconds > 0 else { return nil }
        return receivedAt.addingTimeInterval(seconds)
    }
}

struct AdapterContext: Sendable {
    typealias Send = @Sendable (ActiveRequestKind, UpstreamCall) async throws -> ReceivedReply

    let target: ActiveTarget
    let authIndex: String
    let scope: ActiveScope
    let send: Send
    let pause: @Sendable (Duration) async -> Void
    let partial: PartialQuota

    func call(_ kind: ActiveRequestKind, _ url: URL, method: HTTPMethod = .get, headers: [String: String], data: String? = nil) async throws -> ReceivedReply {
        try await send(kind, UpstreamCall(authIndex: authIndex, method: method, url: url, headers: headers, data: data))
    }

    func json(_ kind: ActiveRequestKind, _ url: URL, method: HTTPMethod = .get, headers: [String: String], data: String? = nil) async throws -> ProviderAnswer {
        let received = try await call(kind, url, method: method, headers: headers, data: data)
        guard let object = received.reply.json else { throw UpstreamFailure.unreadable }
        return ProviderAnswer(object: object, receivedAt: received.receivedAt)
    }

    func optional(_ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch let failure as UpstreamFailure where !failure.stopsTheRefresh {
            return
        }
    }
}

enum ActiveQuotaAdapters {
    static func run(_ context: AdapterContext) async throws {
        switch context.target.provider {
        case "claude": try await ClaudeAdapter.run(context)
        case "codex": try await CodexAdapter.run(context)
        case "antigravity": try await AntigravityAdapter.run(context)
        case "kimi": try await KimiAdapter.run(context)
        case "devin": try await DevinAdapter.run(context)
        case "xai": try await XAIAdapter.run(context)
        default: throw UpstreamFailure.unreadable
        }
    }

    static func requests(for target: ActiveTarget, scope: ActiveScope) -> [ActiveRequestKind] {
        if scope.isPaidKeyContinuation { return [.paidKeyCheck] }
        return switch target.provider {
        case "claude":
            [.usage] + (scope.includesProfile ? [.profile] : []) + (scope.includesResetInventory ? [.resetGrants] : [])
        case "codex":
            [.usage] + (scope.includesProfile && target.accountID != nil ? [.subscription] : []) + (scope.includesResetInventory ? [.resetCredits] : [])
        case "antigravity":
            [.quotaSummary] + (scope.includesProfile ? [.plan] : [])
        case "kimi":
            [.usage] + (scope.includesProfile ? [.profile] : [])
        case "devin":
            [.userStatus]
        case "xai":
            [.billing] + (scope.includesProfile ? [.plan] : []) + (scope.allowsPaidKeyCheck ? [.paidKeyCheck] : [])
        default:
            []
        }
    }

    static func maximumRequests(for target: ActiveTarget, scope: ActiveScope) -> Int {
        if scope.isPaidKeyContinuation { return 2 }
        return switch target.provider {
        case "claude": requests(for: target, scope: scope).count
        case "codex": requests(for: target, scope: scope).count
        case "antigravity": AntigravityAdapter.summaryURLs.count + (scope.includesProfile ? 1 : 0)
        case "kimi": requests(for: target, scope: scope).count
        case "devin": 1
        case "xai": 2 + (scope.includesProfile ? 2 : 0) + (scope.allowsPaidKeyCheck ? 2 : 0)
        default: 0
        }
    }
}

enum ClaudeAdapter {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let resetGrantsURL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!
    static let headers = [
        "User-Agent": "claude-cli/2.1.280 (external, cli)",
        "Authorization": "Bearer $TOKEN$",
        "Content-Type": "application/json",
        "anthropic-beta": "oauth-2025-04-20"
    ]
    static let resetGrantsDelay: Duration = .seconds(2)

    static func run(_ context: AdapterContext) async throws {
        var usageHeaders = headers
        usageHeaders["Accept"] = "application/json"
        let usage = try await context.json(.usage, usageURL, headers: usageHeaders)
        let windows = self.windows(usage)
        guard !windows.isEmpty || usage.has("five_hour", "seven_day", "extra_usage") else { throw UpstreamFailure.unreadable }
        let extra = extraUsage(usage.object)
        context.partial.record([.windows, .extraUsage], receivedAt: usage.receivedAt) {
            $0.recordReportedWindows(windows, at: usage.receivedAt)
            $0.extraUsage = extra
        }
        if context.scope.includesProfile {
            try await context.optional {
                let profile = try await context.json(.profile, profileURL, headers: headers)
                context.partial.markProfileChecked()
                let plan = plan(profile.object)
                context.partial.record([.plan], receivedAt: profile.receivedAt) { $0.plan = plan }
            }
        }
        if context.scope.includesResetInventory {
            await context.pause(resetGrantsDelay)
            try await context.optional {
                let grants = try await context.json(.resetGrants, resetGrantsURL, headers: headers)
                let resets = try? resets(grants["cedar_ember"], at: grants.receivedAt)
                context.partial.record([.resets], receivedAt: grants.receivedAt) { $0.resets = resets }
            }
        }
    }

    static func windows(_ usage: ProviderAnswer) -> [QuotaBar] {
        var bars: [QuotaBar] = []
        for (key, id) in [("five_hour", "session_5h"), ("seven_day", "weekly_all")] {
            if let window = ProviderJSON.object(usage[key]) {
                bars.append(bar(window, id: id, usage: usage))
            }
        }
        if let fable = fableWindow(usage.object) {
            bars.append(bar(fable, id: "weekly_fable", usage: usage))
        }
        return bars
    }

    private static func bar(_ window: [String: Any], id: String, usage: ProviderAnswer) -> QuotaBar {
        usage.bar(id, used: ProviderJSON.number(window["utilization"] ?? window["percent"]), resetsAt: ProviderJSON.date(window["resets_at"]))
    }

    private static func fableWindow(_ payload: [String: Any]) -> [String: Any]? {
        let scoped = ProviderJSON.array(payload["limits"]).compactMap(ProviderJSON.object).filter { limit in
            let kind = ProviderJSON.string(limit["kind"])?.lowercased()
            let model = ProviderJSON.string(ProviderJSON.object(ProviderJSON.object(limit["scope"])?["model"])?["display_name"])?.lowercased()
            return kind == "weekly_scoped" && (model == "fable" || model == "fable 5")
        }
        if let limit = scoped.first(where: { ProviderJSON.bool($0["is_active"]) == true }) ?? scoped.first {
            return limit
        }
        guard let named = ProviderJSON.object(payload["iguana_necktie"]),
              ["limit_dollars", "used_dollars", "remaining_dollars"].allSatisfy({ ProviderJSON.number(named[$0]) == nil })
        else { return nil }
        return named
    }

    static func extraUsage(_ payload: [String: Any]) -> ExtraUsage? {
        guard let extra = ProviderJSON.object(payload["extra_usage"]) else { return nil }
        let usage = ExtraUsage(
            isEnabled: ProviderJSON.bool(extra["is_enabled"]),
            used: ProviderJSON.number(extra["used_credits"]).map { $0 / 100 },
            limit: ProviderJSON.number(extra["monthly_limit"]).map { $0 / 100 },
            currency: ProviderJSON.string(extra["currency"])
        )
        return usage.isEnabled == nil && usage.used == nil && usage.limit == nil ? nil : usage
    }

    static func plan(_ profile: [String: Any]) -> String? {
        let organization = ProviderJSON.object(profile["organization"]) ?? [:]
        let account = ProviderJSON.object(profile["account"]) ?? [:]
        let organizationType = ProviderJSON.string(organization["organization_type"])?.lowercased()
        let subscription = ProviderJSON.string(organization["subscription_status"])?.lowercased()
        if organizationType == "claude_team" && subscription == "active" { return "team" }
        let tier = ProviderJSON.string(ProviderJSON.first(organization, "rate_limit_tier", "rateLimitTier"))?.lowercased() ?? ""
        if tier.hasSuffix("claude_max_20x") { return "max 20x" }
        if tier.hasSuffix("claude_max_5x") { return "max 5x" }
        let hasMax = ProviderJSON.bool(account["has_claude_max"])
        let hasPro = ProviderJSON.bool(account["has_claude_pro"])
        if hasMax == true { return "max" }
        if hasPro == true { return "pro" }
        if hasMax == false && hasPro == false { return "free" }
        return nil
    }

    static func resets(_ block: Any?, at now: Date) throws -> ManualResets? {
        guard let block = ProviderJSON.object(block), jsonBool(block["eligible"]) != nil,
              isMissing(block["ineligible_reason"]) || block["ineligible_reason"] is String,
              isMissing(block["at_limit"]) || jsonBool(block["at_limit"]) != nil,
              isMissing(block["cooldown_until"]) || resetGrantDate(block["cooldown_until"]) != nil,
              isMissing(block["weekly_resets_at"]) || resetGrantDate(block["weekly_resets_at"]) != nil,
              isMissing(block["grants"]) || block["grants"] is [Any] else { return nil }
        var seen: Set<String> = []
        var supplies: [ManualResets.Supply] = []
        var total = 0.0
        for raw in ProviderJSON.array(block["grants"]) {
            guard let grant = ProviderJSON.object(raw), let id = grant["id"] as? String,
                  id.wholeMatch(of: /^[a-z0-9_-]{1,40}$/) != nil, seen.insert(id).inserted,
                  let left = try resetCount(grant["resets_left"]),
                  let granted = try resetCount(grant["resets_total"]), left <= granted,
                  isMissing(grant["clears"]) || grant["clears"] is [Any],
                  ["paused", "usable_now", "use_requires_limit", "gives_back_weekly"].allSatisfy({ isMissing(grant[$0]) || jsonBool(grant[$0]) != nil }) else { return nil }
            let startsAt = resetGrantDate(grant["starts_at"])
            let endsAt = resetGrantDate(grant["ends_at"])
            guard isMissing(grant["starts_at"]) || startsAt != nil,
                  isMissing(grant["ends_at"]) || endsAt != nil else { return nil }
            total += Double(granted)
            if left > 0 {
                supplies.append(ManualResets.Supply(count: left, startsAt: startsAt, endsAt: endsAt, paused: jsonBool(grant["paused"]) == true))
            }
        }
        return try ManualResets(supplies: supplies, total: ProviderJSON.wholeNumber(total), at: now)
    }

    private static func resetCount(_ value: Any?) throws -> Int? {
        guard value is NSNumber, let number = ProviderJSON.number(value), number == number.rounded(.towardZero), number >= 0 else { return nil }
        return try ProviderJSON.wholeNumber(number)
    }

    private static func isMissing(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    private static func jsonBool(_ value: Any?) -> Bool? {
        value is NSNumber ? ProviderJSON.bool(value) : nil
    }

    private static func resetGrantDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.wholeMatch(of: /^\d{4}-\d{2}-\d{2}$/) != nil { return WireDate.parse(text + "T00:00:00Z") }
        let zoneLess = text.wholeMatch(of: /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?$/) != nil
        return WireDate.parse(zoneLess ? text + "Z" : text)
    }
}

enum CodexAdapter {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let subscriptionURL = URL(string: "https://chatgpt.com/backend-api/subscriptions")!
    static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    static let baseHeaders = [
        "Authorization": "Bearer $TOKEN$",
        "Content-Type": "application/json",
        "User-Agent": "codex-tui/0.149.1 (Mac OS 26.5.2; arm64) iTerm.app/3.6.11 (codex-tui; 0.149.1)"
    ]
    static let fiveHourSeconds = 18_000.0
    static let weekSeconds = 604_800.0
    static let resetCreditKeys = ["rate_limit_reset_credits", "rateLimitResetCredits"]

    static func headers(_ target: ActiveTarget) -> [String: String] {
        var headers = baseHeaders
        if let accountID = target.accountID { headers["Chatgpt-Account-Id"] = accountID }
        return headers
    }

    static func run(_ context: AdapterContext) async throws {
        let headers = headers(context.target)
        let usage = try await context.json(.usage, usageURL, headers: headers)
        let windows = try self.windows(usage)
        let note: ActiveQuotaNote? = isBlockedBeyondItsWindows(usage, windows: windows) ? .limitReached : nil
        let plan = ProviderJSON.string(ProviderJSON.first(usage.object, "plan_type", "planType"))?.lowercased()
        let reportsWindows = usage.has("rate_limit", "rateLimit")
        guard reportsWindows || plan != nil else { throw UpstreamFailure.unreadable }
        let resetsKey = resetCreditKeys.first { usage.has($0) }
        let resets = try resetsKey.flatMap { try resetCredits(usage[$0], at: usage.receivedAt) }
        var fields: Set<ActiveQuotaField> = [.windows, .note, .plan, .credits]
        if resetsKey != nil || context.scope.includesResetInventory { fields.insert(.resets) }
        let credits = credits(usage["credits"])
        context.partial.record(fields, receivedAt: usage.receivedAt) {
            $0.note = note
            $0.recordReportedWindows(windows, at: usage.receivedAt)
            $0.plan = plan
            $0.credits = credits
            $0.resets = resets
        }
        if context.scope.includesProfile, let accountID = context.target.accountID {
            try await context.optional {
                var components = URLComponents(url: subscriptionURL, resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "account_id", value: accountID)]
                let subscription = try await context.json(.subscription, components.url!, headers: headers)
                context.partial.markProfileChecked()
                let activeUntil = ProviderJSON.date(ProviderJSON.first(subscription.object, "active_until", "activeUntil"))
                context.partial.record([.planActiveUntil], receivedAt: subscription.receivedAt) { $0.planActiveUntil = activeUntil }
            }
        }
        if context.scope.includesResetInventory {
            try await context.optional {
                var inventoryHeaders = headers
                inventoryHeaders["Accept"] = "application/json"
                inventoryHeaders["OpenAI-Beta"] = "codex-1"
                inventoryHeaders["Originator"] = "Codex Desktop"
                let inventory = try await context.json(.resetCredits, resetCreditsURL, headers: inventoryHeaders)
                let resets = try resetCredits(inventory.object, at: inventory.receivedAt)
                context.partial.record([.resets], receivedAt: inventory.receivedAt) { $0.resets = resets }
            }
        }
    }

    static func isBlockedBeyondItsWindows(_ usage: ProviderAnswer, windows: [QuotaBar]) -> Bool {
        guard let limit = rateLimit(usage) else { return false }
        let reached = ProviderJSON.bool(ProviderJSON.first(limit, "limit_reached", "limitReached")) == true || ProviderJSON.bool(limit["allowed"]) == false
        return reached && !windows.contains { ($0.usedPercent ?? 0) >= 100 }
    }

    private static func rateLimit(_ usage: ProviderAnswer) -> [String: Any]? {
        ProviderJSON.object(ProviderJSON.first(usage.object, "rate_limit", "rateLimit"))
    }

    static func windows(_ usage: ProviderAnswer) throws -> [QuotaBar] {
        guard let limit = rateLimit(usage) else { return [] }
        let primary = ProviderJSON.object(ProviderJSON.first(limit, "primary_window", "primaryWindow"))
        let secondary = ProviderJSON.object(ProviderJSON.first(limit, "secondary_window", "secondaryWindow"))
        let candidates = [(primary, "session_5h"), (secondary, "weekly_all")].compactMap { window, fallbackID in
            window.map { window in (window, fallbackID, ProviderJSON.number(ProviderJSON.first(window, "limit_window_seconds", "limitWindowSeconds"))) }
        }
        let explicit = candidates.filter { $0.2 == fiveHourSeconds || $0.2 == weekSeconds }
        let fallback = candidates.filter { $0.2 != fiveHourSeconds && $0.2 != weekSeconds }
        var seen = Set<String>()
        var bars: [QuotaBar] = []
        for (window, fallbackID, seconds) in explicit + fallback {
            let id = try barID(seconds) ?? fallbackID
            guard seen.insert(id).inserted else { continue }
            bars.append(usage.bar(
                id,
                used: ProviderJSON.number(ProviderJSON.first(window, "used_percent", "usedPercent")),
                resetsAt: resetDate(window, usage: usage),
                reportedPeriodSeconds: seconds
            ))
        }
        return bars.sortedForDisplay()
    }

    private static func barID(_ seconds: TimeInterval?) throws -> String? {
        guard let seconds, seconds >= 60 else { return nil }
        if seconds == fiveHourSeconds { return "session_5h" }
        if seconds == weekSeconds { return "weekly_all" }
        return SignalQuotaParser.codexBarID(minutes: try ProviderJSON.wholeNumber(seconds / 60))
    }

    private static func resetDate(_ window: [String: Any], usage: ProviderAnswer) -> Date? {
        ProviderJSON.date(ProviderJSON.first(window, "reset_at", "resetAt"))
            ?? usage.resetDate(afterSeconds: ProviderJSON.first(window, "reset_after_seconds", "resetAfterSeconds"))
    }

    static func credits(_ value: Any?) -> ProviderCredits? {
        guard let credits = ProviderJSON.object(value) else { return nil }
        let unlimited = ProviderJSON.bool(credits["unlimited"]) == true
        let balance = ProviderJSON.number(credits["balance"])
        guard balance != nil || unlimited else { return nil }
        return ProviderCredits(balance: balance, unlimited: unlimited)
    }

    static func resetCredits(_ value: Any?, at now: Date) throws -> ManualResets? {
        guard let inventory = ProviderJSON.object(value) else { return nil }
        let credits = inventory["credits"] as? [Any]
        let reported = ProviderJSON.number(ProviderJSON.first(inventory, "available_count", "availableCount"))
        if credits == nil {
            guard let reported, try ProviderJSON.wholeNumber(reported) == 0 else { return nil }
        }
        let supplies = (credits ?? []).compactMap(ProviderJSON.object).compactMap { credit -> ManualResets.Supply? in
            guard ProviderJSON.string(ProviderJSON.first(credit, "reset_type", "resetType")) == "codex_rate_limits",
                  ProviderJSON.string(credit["status"]) == "available",
                  let end = ProviderJSON.date(ProviderJSON.first(credit, "expires_at", "expiresAt")) else { return nil }
            return ManualResets.Supply(count: 1, endsAt: end)
        }
        return try ManualResets(supplies: supplies, at: now)
    }
}

enum AntigravityAdapter {
    static let summaryURLs = [
        URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!,
        URL(string: "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary")!,
        URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    ]
    static let planURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let headers = [
        "Authorization": "Bearer $TOKEN$",
        "Content-Type": "application/json",
        "User-Agent": "antigravity/hub/2.23.0 darwin/arm64"
    ]
    static let planBody = #"{"metadata":{"ideType":"ANTIGRAVITY"}}"#
    static let plansByTier = ["free-tier": "free", "g1-pro-tier": "pro", "g1-ultra-tier": "ultra", "g1-ultra-lite-tier": "ultra lite"]

    static func run(_ context: AdapterContext) async throws {
        guard let project = context.target.projectID else { throw UpstreamFailure.unreadable }
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["project": project]), as: UTF8.self)
        var found: (windows: [QuotaBar], receivedAt: Date)?
        var lastFailure: UpstreamFailure = .unreadable
        for url in summaryURLs where found == nil {
            do {
                let summary = try await context.json(.quotaSummary, url, method: .post, headers: headers, data: body)
                let windows = self.windows(summary)
                if !windows.isEmpty { found = (windows, summary.receivedAt) }
            } catch UpstreamFailure.upstream(status: 404) {
                lastFailure = .upstream(status: 404)
            }
        }
        guard let found else { throw lastFailure }
        context.partial.record([.windows], receivedAt: found.receivedAt) { $0.windows = found.windows }
        if context.scope.includesProfile {
            try await context.optional {
                let payload = try await context.json(.plan, planURL, method: .post, headers: headers, data: planBody)
                context.partial.markProfileChecked()
                guard let plan = plan(payload.object) else { return }
                context.partial.record([.plan], receivedAt: payload.receivedAt) { $0.plan = plan }
            }
        }
    }

    static func windows(_ summary: ProviderAnswer) -> [QuotaBar] {
        ProviderJSON.array(summary["groups"]).compactMap(ProviderJSON.object).enumerated().flatMap { groupIndex, group in
            let groupName = ProviderJSON.string(ProviderJSON.first(group, "displayName", "display_name")) ?? "Group \(groupIndex + 1)"
            return ProviderJSON.array(group["buckets"]).compactMap(ProviderJSON.object).enumerated().compactMap { bucketIndex, bucket -> QuotaBar? in
                guard var fraction = ProviderJSON.number(ProviderJSON.first(bucket, "remainingFraction", "remaining_fraction")) else { return nil }
                if fraction > 1 { fraction /= 100 }
                let window = ProviderJSON.string(bucket["window"])
                let bucketName = ProviderJSON.string(ProviderJSON.first(bucket, "displayName", "display_name", "description")) ?? window ?? "\(bucketIndex + 1)"
                let id = "antigravity_" + ProviderJSON.slug(groupName) + "_" + ProviderJSON.slug(window ?? String(bucketIndex + 1))
                return summary.bar(
                    id,
                    used: (1 - min(1, max(0, fraction))) * 100,
                    resetsAt: ProviderJSON.date(ProviderJSON.first(bucket, "resetTime", "reset_time")),
                    label: groupName + " · " + bucketName
                )
            }
        }
    }

    static func plan(_ payload: [String: Any]) -> String? {
        let paid = ProviderJSON.object(ProviderJSON.first(payload, "paidTier", "paid_tier"))
        let current = ProviderJSON.object(ProviderJSON.first(payload, "currentTier", "current_tier"))
        let tier = ProviderJSON.string(paid?["id"]) != nil ? paid : current
        if let id = ProviderJSON.string(tier?["id"]), let plan = plansByTier[id] { return plan }
        return ProviderJSON.string(tier?["name"])?.lowercased()
    }
}

enum KimiAdapter {
    static let comUsageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    static let aiUsageURL = URL(string: "https://api.kimi.ai/coding/v1/usages")!

    static func usageURL(_ domain: KimiDomain) -> URL {
        domain == .ai ? aiUsageURL : comUsageURL
    }

    static func run(_ context: AdapterContext) async throws {
        let url = usageURL(context.target.kimiDomain)
        let usage = try await context.json(.usage, url, headers: ["Authorization": "Bearer $TOKEN$"])
        let windows = try self.windows(usage)
        guard !windows.isEmpty else { throw UpstreamFailure.unreadable }
        context.partial.record([.windows], receivedAt: usage.receivedAt) { $0.windows = windows }
        if context.scope.includesProfile {
            try await context.optional {
                let profile = try await context.json(.profile, url.deletingLastPathComponent().appending(path: "me"), headers: ["Authorization": "Bearer $TOKEN$", "Accept": "application/json"])
                context.partial.markProfileChecked()
                guard ProviderJSON.string(profile["user_id"]) != nil, let plan = ProviderJSON.string(profile["user_level_name"]) else { return }
                context.partial.record([.plan], receivedAt: profile.receivedAt) { $0.plan = plan }
            }
        }
    }

    static func windows(_ usage: ProviderAnswer) throws -> [QuotaBar] {
        var bars: [QuotaBar] = []
        var seen = Set<String>()
        func append(_ bar: QuotaBar?) {
            guard let bar, seen.insert(bar.id).inserted else { return }
            bars.append(bar)
        }
        for (index, item) in ProviderJSON.array(usage["limits"]).compactMap(ProviderJSON.object).enumerated() {
            let detail = ProviderJSON.object(item["detail"]) ?? item
            let window = ProviderJSON.object(item["window"]) ?? [:]
            let minutes = try durationMinutes(window, item, detail)
            let name = ProviderJSON.string(ProviderJSON.first(item, "name", "title", "scope") ?? ProviderJSON.first(detail, "name", "title"))
            let id = minutes.map { SignalQuotaParser.codexBarID(minutes: $0) } ?? "kimi_limit_\(index + 1)"
            append(row(detail, id: id, label: name, usage: usage))
        }
        if let summary = ProviderJSON.object(usage["usage"]) {
            append(row(summary, id: "weekly_all", label: nil, usage: usage))
        }
        if let monthly = ProviderJSON.object(ProviderJSON.object(usage["usages"])?["limit_month_total"]),
           let ratio = ProviderJSON.number(monthly["used_ratio"]) {
            append(usage.bar("monthly", used: ratio * 100, resetsAt: ProviderJSON.date(monthly["reset_time"])))
        }
        return bars
    }

    private static func row(_ data: [String: Any], id: String, label: String?, usage: ProviderAnswer) -> QuotaBar? {
        guard let limit = ProviderJSON.number(data["limit"]), limit > 0 else { return nil }
        let used = ProviderJSON.number(data["used"]) ?? ProviderJSON.number(data["remaining"]).map { limit - $0 }
        guard let used else { return nil }
        return usage.bar(id, used: used / limit * 100, resetsAt: resetDate(data, usage: usage), label: label)
    }

    private static func resetDate(_ data: [String: Any], usage: ProviderAnswer) -> Date? {
        ProviderJSON.date(ProviderJSON.first(data, "reset_at", "resetAt", "reset_time", "resetTime"))
            ?? usage.resetDate(afterSeconds: ProviderJSON.first(data, "reset_in", "resetIn", "ttl"))
    }

    private static func durationMinutes(_ sources: [String: Any]...) throws -> Int? {
        guard let source = sources.first(where: { ProviderJSON.number($0["duration"]) != nil }),
              let duration = ProviderJSON.number(source["duration"]), duration > 0
        else { return nil }
        let unit = (ProviderJSON.string(sources.lazy.compactMap { $0["timeUnit"] }.first) ?? "")
            .uppercased()
            .replacingOccurrences(of: "TIME_UNIT_", with: "")
        let minutes: Double = switch unit {
        case "SECOND", "SECONDS": duration / 60
        case "HOUR", "HOURS": duration * 60
        case "DAY", "DAYS": duration * 1_440
        case "WEEK", "WEEKS": duration * 10_080
        default: duration
        }
        return minutes >= 1 ? try ProviderJSON.wholeNumber(minutes) : nil
    }
}

enum DevinAdapter {
    static let statusURL = URL(string: "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus")!
    static let headers = ["Content-Type": "application/json", "Connect-Protocol-Version": "1"]
    static let body = #"{"metadata":{"apiKey":"$TOKEN$","clientName":"chisel","extensionVersion":"3000.10.21","ideName":"chisel","ideVersion":"3000.10.21","locale":"en","os":"darwin"}}"#

    static func run(_ context: AdapterContext) async throws {
        let payload = try await context.json(.userStatus, statusURL, method: .post, headers: headers, data: body)
        let status = ProviderJSON.object(ProviderJSON.object(payload["userStatus"])?["planStatus"]) ?? [:]
        let windows = [("daily", "daily"), ("weekly", "weekly_all")].compactMap { key, id -> QuotaBar? in
            guard let remaining = ProviderJSON.number(status["\(key)QuotaRemainingPercent"]), (0...100).contains(remaining) else { return nil }
            return payload.bar(id, used: 100 - remaining, resetsAt: ProviderJSON.date(status["\(key)QuotaResetAtUnix"]))
        }
        guard !windows.isEmpty else { throw UpstreamFailure.unreadable }
        let plan = ProviderJSON.string(ProviderJSON.object(status["planInfo"])?["planName"])?.lowercased()
        context.partial.record(plan == nil ? [.windows] : [.windows, .plan], receivedAt: payload.receivedAt) {
            $0.windows = windows
            if let plan { $0.plan = plan }
        }
    }
}

enum XAIAdapter {
    static let weeklyBillingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let monthlyBillingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    static let userURL = URL(string: "https://cli-chat-proxy.grok.com/v1/user?include=subscription")!
    static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    static let apiProfileURL = URL(string: "https://api.x.ai/v1/me")!
    static let completionURL = URL(string: "https://api.x.ai/v1/chat/completions")!
    static let headers = [
        "Authorization": "Bearer $TOKEN$",
        "x-xai-token-auth": "xai-grok-cli",
        "x-grok-client-version": "1.0.70",
        "accept": "*/*",
        "user-agent": "grok-pager/1.0.70 grok-shell/1.0.70 (macos; aarch64)"
    ]
    static let apiHeaders = ["Authorization": "Bearer $TOKEN$", "accept": "application/json"]
    static let completionBody = #"{"max_tokens":1,"messages":[{"content":"ping","role":"user"}],"model":"grok-4.5","stream":false}"#

    struct Billing {
        var window: QuotaBar?
        var credits: ProviderCredits?
        var extraUsage: ExtraUsage?
    }

    enum BillingAnswer {
        case answered(Billing?, receivedAt: Date)
        case failed(UpstreamFailure)
    }

    static func run(_ context: AdapterContext) async throws {
        if context.scope.isPaidKeyContinuation {
            try await paidKeyCheck(context)
            return
        }
        var summary: Billing?
        var billingFailure: UpstreamFailure?
        for url in [weeklyBillingURL, monthlyBillingURL] {
            switch try await billing(url, context: context) {
            case .failed(let failure):
                billingFailure = failure
            case .answered(let answer, let receivedAt):
                guard let answer else { continue }
                let merged = merge(summary, answer)
                summary = merged
                record(merged, receivedAt: receivedAt, in: context.partial)
            }
        }
        if summary == nil {
            if let billingFailure { throw billingFailure }
            guard context.scope.allowsPaidKeyCheck else { throw UpstreamFailure.requiresPaidKeyConsent }
            try await paidKeyCheck(context)
        }
        if context.scope.includesProfile {
            var tier: String?
            var display: String?
            var receivedAt: Date?
            try await context.optional {
                let user = try await context.json(.plan, userURL, headers: headers)
                context.partial.markProfileChecked()
                tier = ProviderJSON.string(ProviderJSON.first(user.object, "subscriptionTier", "subscription_tier"))
                receivedAt = user.receivedAt
            }
            try await context.optional {
                let settings = try await context.json(.plan, settingsURL, headers: headers)
                context.partial.markProfileChecked()
                display = ProviderJSON.string(ProviderJSON.first(settings.object, "subscription_tier_display", "subscriptionTierDisplay"))
                receivedAt = settings.receivedAt
            }
            if let plan = display ?? tier, let receivedAt {
                context.partial.record([.plan], receivedAt: receivedAt) { $0.plan = plan }
            }
        }
    }

    private static func paidKeyCheck(_ context: AdapterContext) async throws {
        try await context.optional { _ = try await context.call(.paidKeyCheck, apiProfileURL, headers: apiHeaders) }
        var completionHeaders = apiHeaders
        completionHeaders["Content-Type"] = "application/json"
        let completion = try await context.call(.paidKeyCheck, completionURL, method: .post, headers: completionHeaders, data: completionBody)
        context.partial.record([.note, .plan], receivedAt: completion.receivedAt) {
            $0.note = .paidKeyAnswered
            $0.plan = "paid"
        }
    }

    private static func record(_ billing: Billing, receivedAt: Date, in partial: PartialQuota) {
        var fields: Set<ActiveQuotaField> = []
        if billing.window != nil { fields.insert(.windows) }
        if billing.credits != nil { fields.insert(.credits) }
        if billing.extraUsage != nil { fields.insert(.extraUsage) }
        partial.record(fields, receivedAt: receivedAt) {
            if let window = billing.window { $0.windows = [window] }
            if let credits = billing.credits { $0.credits = credits }
            if let extraUsage = billing.extraUsage { $0.extraUsage = extraUsage }
        }
    }

    private static func billing(_ url: URL, context: AdapterContext) async throws -> BillingAnswer {
        do {
            let payload = try await context.json(.billing, url, headers: headers)
            return .answered(summary(payload), receivedAt: payload.receivedAt)
        } catch let failure as UpstreamFailure where !failure.stopsTheRefresh {
            return .failed(failure)
        }
    }

    static func summary(_ payload: ProviderAnswer) -> Billing? {
        guard let config = ProviderJSON.object(payload["config"]) else { return nil }
        let period = ProviderJSON.object(ProviderJSON.first(config, "currentPeriod", "current_period"))
        let periodType = ProviderJSON.string(period?["type"])?.lowercased() ?? ""
        let creditPercent = ProviderJSON.number(ProviderJSON.first(config, "creditUsagePercent", "credit_usage_percent"))
        let limitCents = cents(ProviderJSON.first(config, "monthlyLimit", "monthly_limit"))
        let usedCents = cents(config["used"])
        let isWeekly = creditPercent != nil || periodType.contains("weekly")
        let periodEnd = ProviderJSON.date(period?["end"]) ?? ProviderJSON.date(ProviderJSON.first(config, "billingPeriodEnd", "billing_period_end"))
        let monthlyPercent: Double? = if let limitCents, limitCents > 0, let usedCents { min(usedCents, limitCents) / limitCents * 100 } else { nil }
        let used = isWeekly ? creditPercent : monthlyPercent
        let window = used.map { payload.bar(isWeekly ? "weekly_all" : "monthly", used: $0, resetsAt: periodEnd) }
        let prepaid = cents(ProviderJSON.first(config, "prepaidBalance", "prepaid_balance"))
        let onDemandCap = cents(ProviderJSON.first(config, "onDemandCap", "on_demand_cap"))
        let onDemandUsed = cents(ProviderJSON.first(config, "onDemandUsed", "on_demand_used")) ?? {
            guard let usedCents, let limitCents else { return nil }
            return max(0, usedCents - limitCents)
        }()
        guard window != nil || prepaid != nil || limitCents != nil else { return nil }
        return Billing(
            window: window,
            credits: prepaid.map { ProviderCredits(balance: $0 / 100, currency: "USD") },
            extraUsage: onDemandCap.map { ExtraUsage(isEnabled: $0 > 0, used: onDemandUsed.map { $0 / 100 }, limit: $0 / 100, currency: "USD") }
        )
    }

    static func merge(_ earlier: Billing?, _ later: Billing) -> Billing {
        guard let earlier else { return later }
        return Billing(window: earlier.window ?? later.window, credits: earlier.credits ?? later.credits, extraUsage: earlier.extraUsage ?? later.extraUsage)
    }

    private static func cents(_ value: Any?) -> Double? {
        if let object = ProviderJSON.object(value) { return ProviderJSON.number(object["val"]) }
        return ProviderJSON.number(value)
    }
}
