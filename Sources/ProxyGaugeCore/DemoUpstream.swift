import Foundation

enum DemoUpstream {
    struct Reply {
        var status: Int
        var body: String
    }

    static func reply(to url: URL, method: String, account: DemoAccount, now: Date) -> Reply {
        let host = url.host() ?? ""
        let path = url.path()
        let query = url.query() ?? ""
        let object: Any? = switch (host, path) {
        case ("api.anthropic.com", "/api/oauth/usage"): query.contains("cedar_ember") ? claudeGrants(account, now: now) : claudeUsage(account, now: now)
        case ("api.anthropic.com", "/api/oauth/profile"): claudeProfile(account)
        case ("chatgpt.com", "/backend-api/wham/usage"): codexUsage(account, now: now)
        case ("chatgpt.com", "/backend-api/subscriptions"): ["active_until": WireDate.format(now.addingTimeInterval(20 * 86_400))]
        case ("chatgpt.com", "/backend-api/wham/rate-limit-reset-credits"): codexResetCredits(now: now)
        case ("cli-chat-proxy.grok.com", "/v1/billing"): xaiBilling(account, weekly: query.contains("credits"), now: now)
        case ("cli-chat-proxy.grok.com", "/v1/user"): ["subscriptionTier": "SUPERGROK"]
        case ("cli-chat-proxy.grok.com", "/v1/settings"): ["subscription_tier_display": "SuperGrok"]
        default: nil
        }
        guard let object, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return Reply(status: 404, body: #"{"error":"not found"}"#)
        }
        return Reply(status: 200, body: String(decoding: data, as: UTF8.self))
    }

    private static func claudeUsage(_ account: DemoAccount, now: Date) -> [String: Any] {
        let sessionReset = WireDate.format(now.addingTimeInterval(Double(account.sessionResetMinutes) * 60))
        let weeklyReset = WireDate.format(now.addingTimeInterval(Double(account.weeklyResetHours) * 3_600))
        var usage: [String: Any] = [
            "seven_day": ["utilization": min(100, (account.weeklyUsed ?? 0) + 1), "resets_at": weeklyReset]
        ]
        if let sessionUsed = account.sessionUsed {
            usage["five_hour"] = ["utilization": min(100, sessionUsed + 2), "resets_at": sessionReset]
        }
        if let model = account.weeklyModelUsed {
            usage["limits"] = [["kind": "weekly_scoped", "percent": model + 1, "resets_at": weeklyReset, "is_active": true, "scope": ["model": ["display_name": "Fable"]]]]
        }
        if account.label == "Studio" {
            usage["extra_usage"] = ["is_enabled": true, "monthly_limit": 5_000, "used_credits": 1_240, "currency": "USD"]
        }
        return usage
    }

    private static func claudeProfile(_ account: DemoAccount) -> [String: Any] {
        switch account.label {
        case "Studio": ["account": ["has_claude_max": true, "has_claude_pro": false], "organization": ["rate_limit_tier": "default_claude_max_20x"]]
        case "Team": ["account": ["has_claude_max": false, "has_claude_pro": false], "organization": ["organization_type": "claude_team", "subscription_status": "active"]]
        default: ["account": ["has_claude_max": false, "has_claude_pro": true], "organization": ["rate_limit_tier": "default_claude_ai"]]
        }
    }

    private static func claudeGrants(_ account: DemoAccount, now: Date) -> [String: Any] {
        let grants: [[String: Any]] = switch account.label {
        case "Studio": [["id": "grant_demo_1", "resets_total": 3, "resets_left": 2, "ends_at": WireDate.format(now.addingTimeInterval(6 * 86_400)), "usable_now": true]]
        case "Team": [
            ["id": "grant_demo_expired", "resets_total": 2, "resets_left": 2, "ends_at": WireDate.format(now.addingTimeInterval(-86_400))],
            ["id": "grant_demo_paused", "resets_total": 1, "resets_left": 1, "paused": true]
        ]
        default: []
        }
        return ["cedar_ember": ["eligible": account.label != "Lab", "grants": grants]]
    }

    private static func codexUsage(_ account: DemoAccount, now: Date) -> [String: Any] {
        var rateLimit: [String: Any] = [
            "allowed": true,
            "limit_reached": false,
            "secondary_window": ["used_percent": (account.weeklyUsed ?? 0) + 1, "limit_window_seconds": 604_800, "reset_at": Int(now.addingTimeInterval(Double(account.weeklyResetHours) * 3_600).timeIntervalSince1970)]
        ]
        if let sessionUsed = account.sessionUsed {
            rateLimit["primary_window"] = ["used_percent": sessionUsed + 3, "limit_window_seconds": 18_000, "reset_after_seconds": account.sessionResetMinutes * 60]
        }
        return [
            "plan_type": "pro",
            "credits": ["balance": "12.5", "unlimited": false, "has_credits": true],
            "rate_limit": rateLimit
        ]
    }

    private static func codexResetCredits(now: Date) -> [String: Any] {
        ["available_count": 1, "credits": [["id": "credit_demo_1", "reset_type": "codex_rate_limits", "status": "available", "expires_at": WireDate.format(now.addingTimeInterval(9 * 86_400))]]]
    }

    private static func xaiBilling(_ account: DemoAccount, weekly: Bool, now: Date) -> [String: Any] {
        let end = WireDate.format(now.addingTimeInterval(Double(account.weeklyResetHours) * 3_600))
        if weekly {
            return ["config": [
                "creditUsagePercent": account.weeklyUsed ?? 0,
                "currentPeriod": ["type": "BILLING_PERIOD_TYPE_WEEKLY", "start": WireDate.format(now.addingTimeInterval(-3 * 86_400)), "end": end],
                "prepaidBalance": ["val": "2500"]
            ]]
        }
        return ["config": ["monthlyLimit": ["val": 3_000], "used": ["val": 600], "onDemandCap": ["val": 2_000], "onDemandUsed": ["val": 0], "billingPeriodEnd": end]]
    }
}
