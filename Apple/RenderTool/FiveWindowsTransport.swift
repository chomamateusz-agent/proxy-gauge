import Foundation
import ProxyGaugeCore

final class FiveWindowsTransport: HTTPTransport {
    private let demo = DemoTransport()

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var response = try await demo.send(request)
        guard request.url.path().hasSuffix("/v8/management/credentials"),
              var object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let files = object["files"] as? [[String: Any]],
              let template = files.first
        else { return response }
        let now = Date()
        object["files"] = files + Self.extraAccounts(now: now).map { extra in template.merging(extra) { _, new in new } }
        response.body = try JSONSerialization.data(withJSONObject: object)
        return response
    }

    private static func account(_ name: String, provider: String, signals: [String: String], cooldowns: [[String: Any]] = [], now: Date) -> [String: Any] {
        [
            "id": name + ".json",
            "name": name + ".json",
            "auth_index": "fw-" + name,
            "email": name + "@example.com",
            "label": name.capitalized,
            "provider": provider,
            "type": provider,
            "status": "active",
            "status_message": "",
            "disabled": false,
            "unavailable": false,
            "quota_blocked": false,
            "cooldowns": cooldowns,
            "quota": ["signals": signals, "observed_at": WireDate.format(now.addingTimeInterval(-300))]
        ]
    }

    static func extraAccounts(now: Date) -> [[String: Any]] {
        let weeklyReset = String(Int(now.addingTimeInterval(80 * 3_600).timeIntervalSince1970))
        return [
            account("weekly-only", provider: "claude", signals: [
                "Anthropic-Ratelimit-Unified-7d-Utilization": "0.3",
                "Anthropic-Ratelimit-Unified-7d-Reset": weeklyReset,
                "Anthropic-Ratelimit-Unified-7d_oi-Utilization": "0.1",
                "Anthropic-Ratelimit-Unified-7d_oi-Reset": weeklyReset
            ], now: now),
            account("idle", provider: "claude", signals: [
                "Anthropic-Ratelimit-Unified-5h-Utilization": "0",
                "Anthropic-Ratelimit-Unified-7d-Utilization": "0.15",
                "Anthropic-Ratelimit-Unified-7d-Reset": weeklyReset
            ], cooldowns: [[
                "scope": "model",
                "model_key": "claude-opus-5-5",
                "reason": "quota_exhausted",
                "retry_at": WireDate.format(now.addingTimeInterval(35 * 60)),
                "http_status": 429
            ]], now: now),
            account("hourly", provider: "codex", signals: [
                "X-Codex-Primary-Used-Percent": "25",
                "X-Codex-Primary-Window-Minutes": "60",
                "X-Codex-Primary-Reset-After-Seconds": "1800",
                "X-Codex-Secondary-Used-Percent": "40",
                "X-Codex-Secondary-Window-Minutes": "10080",
                "X-Codex-Secondary-Reset-At": weeklyReset
            ], now: now),
            account("pilot", provider: "devin", signals: [
                "daily_quota_remaining_percent": "80",
                "weekly_quota_remaining_percent": "65"
            ], now: now)
        ]
    }
}
