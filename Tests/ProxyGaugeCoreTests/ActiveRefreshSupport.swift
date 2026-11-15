import Foundation
@testable import ProxyGaugeCore

struct UpstreamAnswer: Sendable {
    var status: Int
    var headers: [String: [String]]
    var body: String

    static func json(_ body: String, status: Int = 200, headers: [String: [String]] = [:]) -> UpstreamAnswer {
        UpstreamAnswer(status: status, headers: headers, body: body)
    }

    static func status(_ status: Int, headers: [String: [String]] = [:]) -> UpstreamAnswer {
        UpstreamAnswer(status: status, headers: headers, body: #"{"error":"stub"}"#)
    }
}

final class UpstreamStub: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URL, String) -> UpstreamAnswer

    private let lock = NSLock()
    private var calls: [(method: String, url: URL, authIndex: String, headers: [String: String], data: String?)] = []
    private var running: [String: Int] = [:]
    private var peak: [String: Int] = [:]
    private var runningInTotal = 0
    private var peakInTotal = 0
    private var managementStatus: Int?
    private let delay: Duration
    private let handler: Handler

    init(delay: Duration = .milliseconds(15), handler: @escaping Handler = UpstreamStub.healthy) {
        self.delay = delay
        self.handler = handler
    }

    func rejectManagementKey() {
        lock.withLock { managementStatus = 401 }
    }

    var upstreamURLs: [URL] { lock.withLock { calls.map(\.url) } }
    var upstreamCount: Int { lock.withLock { calls.count } }
    var recordedHeaders: [[String: String]] { lock.withLock { calls.map(\.headers) } }
    var recordedBodies: [String?] { lock.withLock { calls.map(\.data) } }
    var recordedAuthIndexes: [String] { lock.withLock { calls.map(\.authIndex) } }

    func count(host: String) -> Int {
        lock.withLock { calls.filter { $0.url.host() == host }.count }
    }

    func peakConcurrency(host: String) -> Int {
        lock.withLock { peak[host] ?? 0 }
    }

    var peakConcurrencyInTotal: Int { lock.withLock { peakInTotal } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.path().hasSuffix("/v8/management/requests/api-call") else {
            return HTTPResponse(statusCode: 404, body: Data("404 page not found".utf8))
        }
        if let status = lock.withLock({ managementStatus }) {
            return HTTPResponse(statusCode: status, body: Data(#"{"error":"invalid management key"}"#.utf8))
        }
        let envelope = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any] ?? [:]
        let url = URL(string: envelope["url"] as? String ?? "")!
        let method = envelope["method"] as? String ?? ""
        let host = url.host() ?? ""
        lock.withLock {
            calls.append((method, url, envelope["authIndex"] as? String ?? "", envelope["header"] as? [String: String] ?? [:], envelope["data"] as? String))
            running[host, default: 0] += 1
            peak[host] = max(peak[host] ?? 0, running[host] ?? 0)
            runningInTotal += 1
            peakInTotal = max(peakInTotal, runningInTotal)
        }
        try? await Task.sleep(for: delay)
        lock.withLock {
            running[host, default: 1] -= 1
            runningInTotal -= 1
        }
        let answer = handler(url, method)
        let payload: [String: Any] = ["status_code": answer.status, "header": answer.headers, "body": answer.body]
        return HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: payload))
    }

    static let healthy: Handler = { url, _ in
        switch (url.host() ?? "", url.path()) {
        case ("api.anthropic.com", "/api/oauth/usage"):
            if url.query()?.contains("cedar_ember") == true {
                return .json(#"{"cedar_ember":{"eligible":true,"grants":[{"id":"g1","resets_total":3,"resets_left":2,"ends_at":"2026-11-20T10:00:00Z"}]}}"#)
            }
            return .json(#"{"five_hour":{"utilization":40,"resets_at":"2026-11-15T14:00:00Z"},"seven_day":{"utilization":20,"resets_at":"2026-11-19T10:00:00Z"},"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1240,"currency":"USD"}}"#)
        case ("api.anthropic.com", "/api/oauth/profile"):
            return .json(#"{"account":{"has_claude_max":true},"organization":{"rate_limit_tier":"default_claude_max_5x"}}"#)
        case ("chatgpt.com", "/backend-api/wham/usage"):
            return .json(#"{"plan_type":"plus","credits":{"balance":"3.5","unlimited":false},"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_after_seconds":3600},"secondary_window":{"used_percent":55,"limit_window_seconds":604800,"reset_at":1795000000}}}"#)
        case ("chatgpt.com", "/backend-api/subscriptions"):
            return .json(#"{"active_until":"2026-12-01T00:00:00Z"}"#)
        case ("chatgpt.com", "/backend-api/wham/rate-limit-reset-credits"):
            return .json(#"{"available_count":2,"credits":[{"id":"c1","reset_type":"codex_rate_limits","status":"available","expires_at":"2026-11-25T00:00:00Z"}]}"#)
        case ("daily-cloudcode-pa.googleapis.com", "/v1internal:retrieveUserQuotaSummary"):
            return .json(#"{"groups":[{"displayName":"Gemini Pro","buckets":[{"window":"5h","remainingFraction":0.75,"resetTime":"2026-11-15T15:00:00Z"}]}]}"#)
        case ("daily-cloudcode-pa.googleapis.com", "/v1internal:loadCodeAssist"):
            return .json(#"{"paidTier":{"id":"g1-pro-tier","name":"Pro"}}"#)
        case ("api.kimi.com", "/coding/v1/usages"):
            return .json(#"{"usage":{"used":30,"limit":100,"reset_in":7200},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"used":5,"limit":50}}]}"#)
        case ("api.kimi.com", "/coding/v1/me"):
            return .json(#"{"user_id":"u1","user_level_name":"Andante"}"#)
        case ("server.codeium.com", _):
            return .json(#"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":80,"weeklyQuotaRemainingPercent":"65","dailyQuotaResetAtUnix":1795000000,"planInfo":{"planName":"Pro"}}}}"#)
        case ("cli-chat-proxy.grok.com", "/v1/billing"):
            if url.query()?.contains("credits") == true {
                return .json(#"{"config":{"creditUsagePercent":37,"currentPeriod":{"type":"WEEKLY","end":"2026-11-19T00:00:00Z"},"prepaidBalance":{"val":"2500"}}}"#)
            }
            return .json(#"{"config":{"monthlyLimit":{"val":3000},"used":{"val":600}}}"#)
        case ("cli-chat-proxy.grok.com", "/v1/user"):
            return .json(#"{"subscriptionTier":"SUPERGROK"}"#)
        case ("cli-chat-proxy.grok.com", "/v1/settings"):
            return .json(#"{"subscription_tier_display":"SuperGrok"}"#)
        case ("api.x.ai", _):
            return .json(#"{"user_id":"u"}"#)
        default:
            return .status(404)
        }
    }
}

let activeStart = Date(timeIntervalSince1970: 1_794_700_000)

let activeServerID = UUID(uuidString: "00000000-0000-4000-8000-0000000AC71E")!

let activeServer = ActiveRefreshServer(serverID: activeServerID, baseURL: testBaseURL, generation: 0)

func target(_ provider: String, _ id: String, accountID: String? = nil, projectID: String? = nil, disabled: Bool = false) -> ActiveTarget {
    ActiveTarget(credentialID: id, authIndex: id, provider: provider, label: "\(provider)-\(id)@example.com", disabled: disabled, accountID: accountID, projectID: projectID)
}

func coordinator(_ store: any ActiveRefreshStore, clock: TestClock, jitter: Double = 0) -> ActiveRefreshCoordinator {
    ActiveRefreshCoordinator(store: store, clock: { clock.now }, jitter: { jitter }, pause: { _ in })
}

func run(_ coordinator: ActiveRefreshCoordinator, _ targets: [ActiveTarget], mode: ActiveRefreshMode = .manual, through stub: UpstreamStub) async -> [ActiveRefreshResult] {
    let client = ManagementClient(baseURL: testBaseURL, managementKey: "test-key", transport: stub)
    return await coordinator.refresh(targets, server: activeServer, mode: mode) { try await client.apiCall($0, hooks: $1) }
}

extension ActiveRefreshOutcome {
    var quota: ActiveQuota? {
        switch self {
        case .refreshed(let quota): quota
        case .rateLimited(_, let partial): partial
        case .stopped(let partial): partial
        default: nil
        }
    }
}
