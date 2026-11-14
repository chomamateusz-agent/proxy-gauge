import Foundation

public final class DemoTransport: HTTPTransport {
    public static let shared = DemoTransport()
    public static let secret = "demo"

    private let server: DemoServer

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        server = DemoServer(clock: clock)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await Task.sleep(for: .milliseconds(150))
        return await server.handle(request)
    }
}

struct DemoAccount: Sendable {
    var name: String
    var authIndex: String
    var provider: String
    var email: String?
    var projectID: String?
    var label: String
    var plan: String?
    var disabled: Bool
    var status: String
    var statusMessage: String?
    var cooldownMinutes: Int?
    var sessionUsed: Double?
    var weeklyUsed: Double?
    var weeklyModelUsed: Double?
    var sessionResetMinutes: Int
    var weeklyResetHours: Int
    var success: Int64
    var failed: Int64
    var seed: Int
    var models: [String]
}

actor DemoServer {
    private let clock: @Sendable () -> Date
    private var accounts: [DemoAccount]
    private var strategy = "round-robin"
    private var configRevision = 1

    init(clock: @escaping @Sendable () -> Date) {
        self.clock = clock
        accounts = DemoServer.initialAccounts
    }

    static let claudeModels = ["claude-opus-5-5", "claude-sonnet-5-5"]
    static let codexModels = ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna"]
    static let geminiModels = ["gemini-3-pro", "gemini-3-flash"]

    static let initialAccounts: [DemoAccount] = [
        DemoAccount(name: "claude-studio.json", authIndex: "a1f3c9", provider: "claude", email: "studio@example.com", label: "Studio", plan: "max", disabled: false, status: "active", cooldownMinutes: nil, sessionUsed: 42, weeklyUsed: 63, weeklyModelUsed: 18, sessionResetMinutes: 134, weeklyResetHours: 61, success: 18_402, failed: 211, seed: 3, models: claudeModels),
        DemoAccount(name: "claude-team.json", authIndex: "b72e04", provider: "claude", email: "team@example.com", label: "Team", plan: "max", disabled: false, status: "active", cooldownMinutes: 47, sessionUsed: 100, weeklyUsed: 88, weeklyModelUsed: 40, sessionResetMinutes: 47, weeklyResetHours: 30, success: 25_118, failed: 655, seed: 7, models: claudeModels),
        DemoAccount(name: "claude-lab.json", authIndex: "c0d915", provider: "claude", email: "lab@example.com", label: "Lab", plan: "pro", disabled: false, status: "active", cooldownMinutes: nil, sessionUsed: 12, weeklyUsed: 34, weeklyModelUsed: nil, sessionResetMinutes: 260, weeklyResetHours: 118, success: 6_930, failed: 48, seed: 11, models: claudeModels),
        DemoAccount(name: "codex-main.json", authIndex: "d4a7b2", provider: "codex", email: "codex@example.com", label: "Main", plan: "pro", disabled: false, status: "active", cooldownMinutes: nil, sessionUsed: 38, weeklyUsed: 71, weeklyModelUsed: nil, sessionResetMinutes: 90, weeklyResetHours: 75, success: 12_604, failed: 97, seed: 5, models: codexModels),
        DemoAccount(name: "codex-backup.json", authIndex: "e19f60", provider: "codex", email: "backup@example.com", label: "Backup", plan: "plus", disabled: true, status: "disabled", cooldownMinutes: nil, sessionUsed: 5, weeklyUsed: 22, weeklyModelUsed: nil, sessionResetMinutes: 200, weeklyResetHours: 140, success: 1_212, failed: 9, seed: 13, models: codexModels),
        DemoAccount(name: "gemini-cli-research.json", authIndex: "f83c1d", provider: "gemini-cli", email: nil, projectID: "research-demo-4821", label: "Research", plan: nil, disabled: false, status: "active", cooldownMinutes: nil, sessionUsed: nil, weeklyUsed: nil, weeklyModelUsed: nil, sessionResetMinutes: 0, weeklyResetHours: 0, success: 3_377, failed: 140, seed: 17, models: geminiModels),
        DemoAccount(name: "gemini-cli-sandbox.json", authIndex: "07be55", provider: "gemini-cli", email: nil, projectID: "sandbox-demo-0193", label: "Sandbox", plan: nil, disabled: false, status: "error", statusMessage: "token refresh failed: invalid_grant", cooldownMinutes: nil, sessionUsed: nil, weeklyUsed: nil, weeklyModelUsed: nil, sessionResetMinutes: 0, weeklyResetHours: 0, success: 402, failed: 61, seed: 19, models: geminiModels)
    ]

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.url.path()
        let route = DemoRoute(method: request.method, path: path)
        let now = clock()
        switch route {
        case .health:
            return json(["status": "ok"])
        case .credentials:
            return json(credentialList(now: now), versioned: true)
        case .setStatus:
            return setStatus(request.body)
        case .resetCooldown:
            return resetCooldown(request.body)
        case .readStrategy:
            var response = json(strategy, versioned: true)
            response.setHeader("ETag", configETag)
            return response
        case .writeStrategy:
            return writeStrategy(request)
        case .upstreamKeys:
            return json(upstreamKeyUsage(), versioned: true)
        case .clientKeyPolicies:
            return json(clientKeyPolicies(), versioned: true)
        case .credentialModels:
            return credentialModels(request.url)
        case .clientKeyUsage:
            return json(clientKeyUsage(now: now), versioned: true)
        case .clientModels:
            return json(clientModels())
        case .fleetLimits:
            return json(fleetLimits(now: now))
        case .unknown:
            return HTTPResponse(statusCode: 404, body: Data("404 page not found".utf8))
        }
    }

    private func json(_ object: Any, versioned: Bool = false) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
        var headers = ["Content-Type": "application/json; charset=utf-8"]
        if versioned {
            headers["X-CPA-VERSION"] = "8.0.69"
            headers["X-CPA-COMMIT"] = "c41d9e07"
            headers["X-CPA-BUILD-DATE"] = "2026-11-12T18:27:10Z"
        }
        return HTTPResponse(statusCode: 200, headers: headers, body: data)
    }

    private func failure(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data())
    }

    private func setStatus(_ body: Data?) -> HTTPResponse {
        guard let object = body.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              let name = object["name"] as? String,
              let disabled = object["disabled"] as? Bool
        else { return failure(400, "invalid body") }
        guard let index = accounts.firstIndex(where: { $0.name == name }) else { return failure(404, "auth file not found") }
        accounts[index].disabled = disabled
        accounts[index].status = disabled ? "disabled" : "active"
        return json(["status": "ok", "disabled": disabled])
    }

    private func resetCooldown(_ body: Data?) -> HTTPResponse {
        guard let object = body.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              let authIndex = object["auth_index"] as? String, !authIndex.isEmpty
        else { return failure(400, "auth_index is required") }
        guard let index = accounts.firstIndex(where: { $0.authIndex == authIndex }) else { return failure(404, "auth not found") }
        accounts[index].cooldownMinutes = nil
        return json(["status": "ok", "auth_index": authIndex, "models": accounts[index].models])
    }

    private var configETag: String { "\"demo-config-\(configRevision)\"" }

    private func writeStrategy(_ request: HTTPRequest) -> HTTPResponse {
        if let expected = request.headers["If-Match"], expected != configETag {
            var response = failure(412, "precondition_failed")
            response.setHeader("ETag", configETag)
            return response
        }
        guard let value = request.body.flatMap({ try? JSONDecoder().decode(String.self, from: $0) }),
              ManagementClient.routingStrategies.contains(value)
        else { return failure(400, "invalid strategy") }
        strategy = value
        configRevision += 1
        var response = json(["config-version": 8, "status": "ok"])
        response.setHeader("ETag", configETag)
        return response
    }

    private func clientKeyPolicies() -> [[String: Any]] {
        ["laptop", "ci", "phone"].enumerated().map { index, name in
            [
                "index": index, "name": name, "has_policy": false, "issued-by": "", "expires-at": "",
                "models": [String](), "excluded-models": [String](), "credentials": [String](), "excluded-credentials": [String]()
            ]
        }
    }

    private func credentialModels(_ url: URL) -> HTTPResponse {
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value
        guard let name, !name.isEmpty else { return failure(400, "name is required") }
        let models = accounts.first { $0.name == name }?.models ?? []
        return json(["models": models.map { ["id": $0, "display_name": $0, "type": "chat", "owned_by": ownerOf($0)] }])
    }

    private func credentialList(now: Date) -> [String: Any] {
        ["observed_at": WireDate.format(now), "files": accounts.map { credentialJSON($0, now: now) }]
    }

    private func credentialJSON(_ account: DemoAccount, now: Date) -> [String: Any] {
        var entry: [String: Any] = [
            "id": account.name,
            "auth_index": account.authIndex,
            "name": account.name,
            "type": account.provider,
            "provider": account.provider,
            "label": account.label,
            "status": account.status,
            "status_message": account.statusMessage ?? "",
            "disabled": account.disabled,
            "unavailable": account.cooldownMinutes != nil || account.status == "error",
            "runtime_only": false,
            "source": "file",
            "size": 1_843,
            "success": account.success,
            "failed": account.failed,
            "recent_requests": recentRequests(account, now: now),
            "quota": quotaJSON(account, now: now),
            "cooldowns": cooldownsJSON(account, now: now),
            "requires_sign_in": false,
            "quota_blocked": account.cooldownMinutes != nil,
            "updated_at": WireDate.format(now.addingTimeInterval(-3_600)),
            "last_refresh": WireDate.format(now.addingTimeInterval(-1_800))
        ]
        if let email = account.email { entry["email"] = email }
        if let projectID = account.projectID { entry["project_id"] = projectID }
        if let cooldown = account.cooldownMinutes {
            entry["next_retry_after"] = WireDate.format(now.addingTimeInterval(Double(cooldown) * 60))
        }
        return entry
    }

    private func cooldownsJSON(_ account: DemoAccount, now: Date) -> [[String: Any]] {
        guard let minutes = account.cooldownMinutes else { return [] }
        return [[
            "scope": "credential",
            "reason": "quota_exhausted",
            "retry_at": WireDate.format(now.addingTimeInterval(Double(minutes) * 60)),
            "remaining_seconds": minutes * 60,
            "backoff_level": 1,
            "http_status": 429
        ]]
    }

    private func quotaJSON(_ account: DemoAccount, now: Date) -> [String: Any] {
        let signals = signalMap(account, now: now)
        if signals.isEmpty { return ["signals": [String: String]()] }
        return ["signals": signals, "observed_at": WireDate.format(now.addingTimeInterval(-240))]
    }

    private func signalMap(_ account: DemoAccount, now: Date) -> [String: String] {
        let sessionReset = now.addingTimeInterval(Double(account.sessionResetMinutes) * 60)
        let weeklyReset = now.addingTimeInterval(Double(account.weeklyResetHours) * 3_600)
        var signals: [String: String] = [:]
        switch account.provider {
        case "claude":
            if let used = account.sessionUsed {
                signals["Anthropic-Ratelimit-Unified-5h-Utilization"] = String(used / 100)
                signals["Anthropic-Ratelimit-Unified-5h-Reset"] = String(Int(sessionReset.timeIntervalSince1970))
                signals["Anthropic-Ratelimit-Unified-5h-Status"] = used >= 100 ? "rejected" : used >= 80 ? "allowed_warning" : "allowed"
            }
            if let used = account.weeklyUsed {
                signals["Anthropic-Ratelimit-Unified-7d-Utilization"] = String(used / 100)
                signals["Anthropic-Ratelimit-Unified-7d-Reset"] = String(Int(weeklyReset.timeIntervalSince1970))
                signals["Anthropic-Ratelimit-Unified-7d-Status"] = used >= 80 ? "allowed_warning" : "allowed"
            }
            if let used = account.weeklyModelUsed {
                signals["Anthropic-Ratelimit-Unified-7d_oi-Utilization"] = String(used / 100)
                signals["Anthropic-Ratelimit-Unified-7d_oi-Reset"] = String(Int(weeklyReset.timeIntervalSince1970))
                signals["Anthropic-Ratelimit-Unified-7d_oi-Status"] = "allowed"
            }
        case "codex":
            if let used = account.sessionUsed {
                signals["X-Codex-Primary-Used-Percent"] = String(used)
                signals["X-Codex-Primary-Window-Minutes"] = "300"
                signals["X-Codex-Primary-Reset-After-Seconds"] = String(account.sessionResetMinutes * 60 + 240)
            }
            if let used = account.weeklyUsed {
                signals["X-Codex-Secondary-Used-Percent"] = String(used)
                signals["X-Codex-Secondary-Window-Minutes"] = "10080"
                signals["X-Codex-Secondary-Reset-At"] = String(Int(weeklyReset.timeIntervalSince1970))
            }
            if let plan = account.plan {
                signals["X-Codex-Plan-Type"] = plan
            }
        default:
            break
        }
        return signals
    }

    private func recentRequests(_ account: DemoAccount, now: Date) -> [[String: Any]] {
        let calendar = Calendar(identifier: .gregorian)
        let minute = calendar.component(.minute, from: now)
        let bucketEnd = now.addingTimeInterval(Double(10 - minute % 10) * 60)
        return (0..<20).map { position in
            let end = bucketEnd.addingTimeInterval(Double(position - 19) * 600)
            let start = end.addingTimeInterval(-600)
            let wave = (sin(Double(position + account.seed) / 2.6) + 1.3) * Double(10 + account.seed)
            let success = account.disabled ? 0 : Int64(wave.rounded())
            let failed = account.disabled ? 0 : Int64((position * account.seed) % 7 == 0 ? 2 : 0)
            return ["time": "\(clockLabel(start, calendar))-\(clockLabel(end, calendar))", "success": success, "failed": failed]
        }
    }

    private func clockLabel(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        return (hour < 10 ? "0" : "") + String(hour) + ":" + (minute < 10 ? "0" : "") + String(minute)
    }

    private func upstreamKeyUsage() -> [String: Any] {
        [
            "openai-compatibility": [
                "https://llm.example.com/v1|demo-upstream-key": ["success": 2_340, "failed": 12, "recent_requests": [[String: Any]]()]
            ]
        ]
    }

    private func clientModels() -> [String: Any] {
        let enabled = accounts.filter { !$0.disabled }
        let ids = Set(enabled.flatMap(\.models)).sorted()
        return ["object": "list", "data": ids.map { id in ["id": id, "object": "model", "created": 1_760_000_000, "owned_by": ownerOf(id)] }]
    }

    private func ownerOf(_ model: String) -> String {
        if model.hasPrefix("claude") { return "anthropic" }
        if model.hasPrefix("gpt") { return "openai" }
        return "google"
    }

    private func clientKeyUsage(now: Date) -> [String: Any] {
        func model(_ provider: String, _ name: String, _ requests: Int, _ input: Int, _ output: Int, _ reasoning: Int, _ cacheRead: Int) -> [String: Any] {
            [
                "provider": provider, "model": name, "requests": requests, "failed_requests": requests / 60,
                "input_tokens": input, "output_tokens": output, "reasoning_tokens": reasoning,
                "cache_read_tokens": cacheRead, "cache_creation_tokens": input / 20,
                "total_tokens": input + output + cacheRead + input / 20
            ]
        }
        func key(_ name: String, _ models: [[String: Any]]) -> [String: Any] {
            func sum(_ field: String) -> Int { models.reduce(0) { $0 + (($1[field] as? Int) ?? 0) } }
            return [
                "name": name, "created_at": WireDate.format(now.addingTimeInterval(-40 * 86_400)), "revoked": false,
                "requests": sum("requests"), "failed_requests": sum("failed_requests"),
                "input_tokens": sum("input_tokens"), "output_tokens": sum("output_tokens"), "reasoning_tokens": sum("reasoning_tokens"),
                "cache_read_tokens": sum("cache_read_tokens"), "cache_creation_tokens": sum("cache_creation_tokens"),
                "total_tokens": sum("total_tokens"), "models": models
            ]
        }
        return [
            "object": "fleet.client_key_usage",
            "generated_at": WireDate.format(now),
            "from": WireDate.format(now.addingTimeInterval(-7 * 86_400)),
            "to": WireDate.format(now),
            "recording_since": WireDate.format(now.addingTimeInterval(-40 * 86_400)),
            "granularity": "hour",
            "keys": [
                key("laptop", [
                    model("claude", "claude-sonnet-5-5", 4_210, 18_400_000, 2_100_000, 0, 41_000_000),
                    model("codex", "gpt-6.1-sol", 1_880, 9_700_000, 1_400_000, 820_000, 12_500_000)
                ]),
                key("ci-runner", [
                    model("codex", "gpt-6-luna", 6_020, 7_900_000, 640_000, 0, 3_100_000),
                    model("gemini-cli", "gemini-3-flash", 990, 2_200_000, 310_000, 120_000, 0)
                ])
            ]
        ]
    }

    private func fleetLimits(now: Date) -> [String: Any] {
        let visible = accounts.filter { $0.provider != "gemini-cli" || $0.status != "error" }
        let credentials: [[String: Any]] = visible.enumerated().map { offset, account in
            let parsed = SignalQuotaParser.bars(
                provider: account.provider,
                observations: [QuotaObservation(signals: signalMap(account, now: now), observedAt: now.addingTimeInterval(-240))]
            )
            var entry: [String: Any] = [
                "label": "\(account.provider)-\(offset + 1)",
                "provider": account.provider,
                "plan": account.plan as Any? ?? NSNull(),
                "state": fleetState(account),
                "bars": parsed.map { bar -> [String: Any] in
                    [
                        "id": bar.id,
                        "percent": bar.usedPercent as Any? ?? NSNull(),
                        "status": bar.status as Any? ?? NSNull(),
                        "resets_at": bar.resetsAt.map(WireDate.format) as Any? ?? NSNull(),
                        "sampled_at": bar.sampledAt.map(WireDate.format) as Any? ?? NSNull(),
                        "reset_passed": false
                    ]
                },
                "cooldowns": account.cooldownMinutes.map { minutes in
                    [["scope": "credential", "model": NSNull(), "reason": "quota_exhausted", "until": WireDate.format(now.addingTimeInterval(Double(minutes) * 60)), "http_status": 429]]
                } ?? []
            ]
            if account.provider == "codex" {
                entry["credits"] = ["has_credits": false, "unlimited": false, "balance": 0]
            }
            return entry
        }
        var summary: [String: Any] = [:]
        for (provider, members) in Dictionary(grouping: visible, by: \.provider) {
            let usable = members.filter { !$0.disabled && $0.cooldownMinutes == nil }
            let barSets = usable.map { account in
                SignalQuotaParser.bars(provider: account.provider, observations: [QuotaObservation(signals: signalMap(account, now: now), observedAt: now)])
            }
            let best = HeadroomCalculator.bestBars(barSets, now: now)
            var bars: [String: Any] = [:]
            for bar in best {
                bars[bar.id] = ["percent": bar.usedPercent ?? 0, "resets_at": bar.resetsAt.map(WireDate.format) as Any? ?? NSNull()]
            }
            summary[provider] = ["usable_credentials": usable.count, "bars": bars]
        }
        return [
            "object": "fleet.limits",
            "generated_at": WireDate.format(now),
            "proxy_version": "8.0.69",
            "client": ["name": "demo-phone"],
            "models": Set(visible.flatMap(\.models)).sorted().map { id in
                ["id": id, "providers": Array(Set(visible.filter { $0.models.contains(id) }.map(\.provider))).sorted()]
            },
            "exclusions": [
                ["pattern": "claude-opus-5-5", "provider": "claude", "source": "key-policy", "until": NSNull(), "until_source": NSNull()]
            ],
            "credentials": credentials,
            "summary": summary
        ]
    }

    private func fleetState(_ account: DemoAccount) -> String {
        if account.disabled { return "disabled" }
        if account.cooldownMinutes != nil { return "cooldown" }
        if account.status == "error" { return "error" }
        return "active"
    }
}

enum DemoRoute {
    case health, credentials, setStatus, resetCooldown, readStrategy, writeStrategy
    case upstreamKeys, clientKeyPolicies, credentialModels, clientKeyUsage, clientModels, fleetLimits, unknown

    init(method: HTTPMethod, path: String) {
        switch (method, path) {
        case (.get, "/healthz"): self = .health
        case (.get, "/v8/management/credentials"): self = .credentials
        case (.patch, "/v8/management/credentials/status"): self = .setStatus
        case (.post, "/v8/management/routing/cooldown/reset"): self = .resetCooldown
        case (.get, "/v8/management/config/routing/strategy"): self = .readStrategy
        case (.put, "/v8/management/config/routing/strategy"): self = .writeStrategy
        case (.get, "/v8/management/observability/usage/api-keys"): self = .upstreamKeys
        case (.get, "/v8/management/client-key-policies"): self = .clientKeyPolicies
        case (.get, "/v8/management/credentials/models"): self = .credentialModels
        case (.get, "/v8/management/usage/client-keys"): self = .clientKeyUsage
        case (.get, "/v1/models"): self = .clientModels
        case (.get, "/v1/fleet/limits"): self = .fleetLimits
        default: self = .unknown
        }
    }
}
