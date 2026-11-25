import Foundation
import ProxyGaugeCore

final class ProviderRenderTransport: HTTPTransport {
    static let rateLimitedAuthIndex = "c0d915"

    private let demo = DemoTransport()
    private let includesApprovalFixtures: Bool

    init(includesApprovalFixtures: Bool = false) {
        self.includesApprovalFixtures = includesApprovalFixtures
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path().hasSuffix("/v8/management/requests/api-call"),
           let body = request.body,
           let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if envelope["authIndex"] as? String == Self.rateLimitedAuthIndex {
                let nested: [String: Any] = ["status_code": 429, "header": ["Retry-After": ["3600"]], "body": #"{"error":"rate_limited"}"#]
                return HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: nested))
            }
            if includesApprovalFixtures, let target = (envelope["url"] as? String).flatMap(URL.init(string:)),
               target.host() == "cli-chat-proxy.grok.com", target.path() == "/v1/billing" {
                let nested: [String: Any] = ["status_code": 200, "header": [String: [String]](), "body": "{}"]
                return HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: nested))
            }
        }
        var response = try await demo.send(request)
        guard includesApprovalFixtures,
              request.url.path().hasSuffix("/v8/management/credentials"),
              var object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let files = object["files"] as? [[String: Any]],
              let template = files.first
        else { return response }
        let extra: [[String: Any]] = [
            ["id": "antigravity-pro.json", "name": "antigravity-pro.json", "auth_index": "ag01", "provider": "antigravity", "type": "antigravity", "email": "builder@example.com", "project_id": "demo-project-0420", "quota": ["signals": [String: String]()], "cooldowns": [[String: Any]]()]
        ]
        object["files"] = files + extra.map { template.merging($0) { _, new in new } }
        response.body = try JSONSerialization.data(withJSONObject: object)
        return response
    }
}
