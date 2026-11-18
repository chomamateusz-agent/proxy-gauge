import Foundation
import ProxyGaugeCore

enum CoolingPoolFixture {
    static let capturedAt = WireDate.parse("2026-11-17T18:48:30Z")!

    static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "docs/fixtures/fleet-limits-cooling-pool.json")

    static func object(shiftedTo now: Date) throws -> [String: Any] {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        return shift(raw, by: now.timeIntervalSince(capturedAt)) as? [String: Any] ?? [:]
    }

    private static func shift(_ value: Any, by offset: TimeInterval) -> Any {
        switch value {
        case let object as [String: Any]: object.mapValues { shift($0, by: offset) }
        case let array as [Any]: array.map { shift($0, by: offset) }
        case let text as String: WireDate.parse(text).map { WireDate.format($0.addingTimeInterval(offset)) } ?? text
        default: value
        }
    }

    static func managementFiles(_ limits: [String: Any]) -> [[String: Any]] {
        let credentials = limits["credentials"] as? [[String: Any]] ?? []
        return credentials.map { credential in
            let label = credential["label"] as? String ?? ""
            let provider = credential["provider"] as? String ?? ""
            let bars = credential["bars"] as? [[String: Any]] ?? []
            let disabled = credential["state"] as? String == "disabled"
            let sampledAt = bars.compactMap { $0["sampled_at"] as? String }.max()
            var file: [String: Any] = [
                "id": label + ".json",
                "name": label + ".json",
                "auth_index": label,
                "label": label,
                "provider": provider,
                "type": provider,
                "status": disabled ? "disabled" : "active",
                "status_message": "",
                "disabled": disabled,
                "unavailable": false,
                "quota_blocked": false,
                "cooldowns": (credential["cooldowns"] as? [[String: Any]] ?? []).map { cooldown in
                    [
                        "scope": cooldown["scope"] ?? "credential",
                        "model_key": cooldown["model"] ?? NSNull(),
                        "reason": cooldown["reason"] ?? "",
                        "retry_at": cooldown["until"] ?? NSNull(),
                        "http_status": cooldown["http_status"] ?? NSNull()
                    ] as [String: Any]
                }
            ]
            if !bars.isEmpty {
                file["quota"] = ["signals": signals(provider: provider, bars: bars), "observed_at": sampledAt ?? NSNull()] as [String: Any]
            }
            return file
        }
    }

    private static func signals(provider: String, bars: [[String: Any]]) -> [String: String] {
        var signals: [String: String] = [:]
        for bar in bars {
            let used = (bar["percent"] as? Double) ?? 0
            let reset = (bar["resets_at"] as? String).flatMap(WireDate.parse).map { String(Int($0.timeIntervalSince1970)) }
            if provider == "codex" {
                signals["X-Codex-Primary-Used-Percent"] = String(used)
                signals["X-Codex-Primary-Window-Minutes"] = String(7 * 24 * 60)
                signals["X-Codex-Primary-Reset-At"] = reset
                continue
            }
            let prefix = switch bar["id"] as? String {
            case "weekly_all": "Anthropic-Ratelimit-Unified-7d-"
            case "weekly_fable": "Anthropic-Ratelimit-Unified-7d_oi-"
            default: "Anthropic-Ratelimit-Unified-5h-"
            }
            signals[prefix + "Utilization"] = String(used / 100)
            signals[prefix + "Status"] = bar["status"] as? String
            signals[prefix + "Reset"] = reset
        }
        return signals
    }
}

final class CoolingPoolTransport: HTTPTransport {
    private let now = Date()

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let limits = try CoolingPoolFixture.object(shiftedTo: now)
        let path = request.url.path()
        if path.hasSuffix("/v1/fleet/limits") {
            return HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: limits))
        }
        if path.hasSuffix("/v8/management/credentials") {
            let list: [String: Any] = ["observed_at": WireDate.format(now), "files": CoolingPoolFixture.managementFiles(limits)]
            return HTTPResponse(statusCode: 200, headers: ["X-CPA-VERSION": "8.0.69"], body: try JSONSerialization.data(withJSONObject: list))
        }
        return HTTPResponse(statusCode: 404, body: Data("404 page not found".utf8))
    }
}
