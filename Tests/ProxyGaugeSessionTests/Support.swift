import Foundation
import ProxyGaugeCore
import ProxyGaugeStore
@testable import ProxyGaugeSession

@MainActor
final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
final class FakeServer {
    static let rejection = HTTPResponse(statusCode: 401, body: Data(#"{"error":"invalid management key"}"#.utf8))

    var keyAccepted = true
    var strategy = "round-robin"
    var configVersion = 1
    var overrides: [String: HTTPResponse] = [:]
    var heldAfterAnswer: [String: Gate] = [:]
    private(set) var log: [String] = []

    var etag: String { "\"\(configVersion)\"" }

    func requests(_ route: String) -> Int {
        log.filter { $0 == route }.count
    }

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        let route = "\(request.method.rawValue) \(request.url.path())"
        log.append(route)
        let response = answer(route, request)
        if let gate = heldAfterAnswer.removeValue(forKey: route) {
            await gate.wait()
        }
        log.append("answered \(route)")
        return response
    }

    private func answer(_ route: String, _ request: HTTPRequest) -> HTTPResponse {
        guard keyAccepted else { return Self.rejection }
        if let override = overrides[route] { return override }
        switch route {
        case "GET /v8/management/credentials":
            return json(#"{"files":[{"name":"a.json","auth_index":"1","provider":"claude","type":"claude"}]}"#)
        case "GET /v8/management/observability/usage/api-keys":
            return json("{}")
        case "GET /v8/management/client-key-policies":
            return json("[]")
        case "GET /v8/management/config/routing/strategy":
            return json("\"\(strategy)\"", headers: ["ETag": etag])
        case "PUT /v8/management/config/routing/strategy":
            if let expected = request.headers["If-Match"], expected != etag {
                return HTTPResponse(statusCode: 412, body: Data())
            }
            strategy = (try? JSONDecoder().decode(String.self, from: request.body ?? Data())) ?? strategy
            configVersion += 1
            return json(#"{"status":"ok"}"#)
        case "PATCH /v8/management/credentials/status", "POST /v8/management/routing/cooldown/reset":
            return json(#"{"status":"ok"}"#)
        default:
            return HTTPResponse(statusCode: 404, body: Data("404 page not found".utf8))
        }
    }

    private func json(_ text: String, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: headers, body: Data(text.utf8))
    }
}

struct FakeServerTransport: HTTPTransport {
    let server: FakeServer

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        await server.respond(to: request)
    }
}

@MainActor
struct SessionHarness {
    let server = FakeServer()
    let store: ProfileStore
    let profile = ServerProfile(name: "Home", baseURL: URL(string: "http://192.168.1.20:8317")!, authMode: .management)
    let secrets = InMemorySecretStore()

    init() {
        let suite = "proxygauge.session-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = ProfileStore(defaults: defaults)
        try? secrets.setSecret("test-key", for: profile.id)
    }

    func makeSession() -> ServerSession {
        ServerSession(profile: profile, secrets: secrets, latchStore: store, transport: FakeServerTransport(server: server))
    }

    func storedPause() -> AuthPauseReason? {
        store.authFailureLatch(for: profile.id, generation: store.authGeneration(for: profile.id)).pauseReason
    }
}

@MainActor
func settle() async {
    for _ in 0..<50 { await Task.yield() }
}
