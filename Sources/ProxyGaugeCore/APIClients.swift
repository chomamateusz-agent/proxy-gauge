import Foundation

struct RequestBuilder: Sendable {
    let baseURL: URL
    let credential: String

    func request(_ method: HTTPMethod = .get, _ path: String, query: [URLQueryItem] = [], json body: Data? = nil, extraHeaders: [String: String] = [:]) -> HTTPRequest {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.append(path: String(component))
        }
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        var headers = [
            "Authorization": "Bearer \(credential)",
            "Accept": "application/json",
            "User-Agent": "ProxyGauge/\(AppVersion.marketing)"
        ]
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        headers.merge(extraHeaders) { _, extra in extra }
        return HTTPRequest(method: method, url: url, headers: headers, body: body)
    }
}

struct Exchange: Sendable {
    let transport: any HTTPTransport
    var ticket: SendGate.Ticket?

    func send(_ request: HTTPRequest, hooks: SendHooks = .none) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await deliver(request, hooks: hooks)
        } catch let error as APIError {
            throw error
        } catch let refusal as SendRefusal {
            throw refusal
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as CancellationError {
            throw error
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard response.isSuccess else { throw APIError.from(response) }
        return response
    }

    private func deliver(_ request: HTTPRequest, hooks: SendHooks) async throws -> HTTPResponse {
        guard let ticket else {
            try await hooks.admitBeforeStarting()
            try hooks.start {}
            return try await transport.send(request)
        }
        return try await ticket.send(request, hooks: hooks, through: transport)
    }

    func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        do {
            return try JSONDecoder.wire().decode(type, from: response.body)
        } catch {
            throw APIError.decoding(String(describing: type))
        }
    }
}

public struct Versioned<Value: Sendable>: Sendable {
    public var value: Value
    public var version: ServerVersion?
}

public struct ManagementClient: Sendable {
    public static let routingStrategies = ["round-robin", "weighted-round-robin", "fill-first"]

    let builder: RequestBuilder
    var exchange: Exchange

    public init(baseURL: URL, managementKey: String, transport: any HTTPTransport) {
        builder = RequestBuilder(baseURL: baseURL, credential: managementKey)
        exchange = Exchange(transport: transport)
    }

    public func sending(under ticket: SendGate.Ticket) -> ManagementClient {
        var gated = self
        gated.exchange.ticket = ticket
        return gated
    }

    public func health() async throws -> Bool {
        let response = try await exchange.send(builder.request(.get, "healthz"))
        return response.isSuccess
    }

    public func credentials() async throws -> Versioned<CredentialList> {
        let response = try await exchange.send(builder.request(.get, "v8/management/credentials"))
        return Versioned(value: try exchange.decode(CredentialList.self, from: response), version: ServerVersion(headers: response))
    }

    public func setDisabled(_ disabled: Bool, credential: Credential) async throws {
        var payload: [String: Any] = ["name": credential.name, "disabled": disabled]
        if let authIndex = credential.authIndex {
            payload["auth_index"] = authIndex
        }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        _ = try await exchange.send(builder.request(.patch, "v8/management/credentials/status", json: body))
    }

    public func resetCooldown(authIndex: String) async throws -> CooldownResetResult {
        let body = try JSONSerialization.data(withJSONObject: ["auth_index": authIndex], options: [.sortedKeys])
        let response = try await exchange.send(builder.request(.post, "v8/management/routing/cooldown/reset", json: body))
        return try exchange.decode(CooldownResetResult.self, from: response)
    }

    public func routingStrategy() async throws -> RoutingStrategySetting? {
        switch try await readRoutingStrategy() {
        case .explicit(let setting):
            return setting
        case .unsupported:
            return nil
        case .absent:
            let version = try await configVersionETag()
            if case .explicit(let setting) = try await readRoutingStrategy() { return setting }
            return RoutingStrategySetting(strategy: RoutingStrategySetting.serverDefault, isExplicit: false, etag: version)
        }
    }

    private enum RoutingRead {
        case explicit(RoutingStrategySetting)
        case absent
        case unsupported
    }

    private func readRoutingStrategy() async throws -> RoutingRead {
        do {
            let response = try await exchange.send(builder.request(.get, "v8/management/config/routing/strategy"))
            return .explicit(RoutingStrategySetting(
                strategy: try exchange.decode(String.self, from: response),
                isExplicit: true,
                etag: response.header("ETag")
            ))
        } catch APIError.notFound(let message) where message == ConfigNode.missingNodeError {
            return .absent
        } catch APIError.notFound(_) {
            return .unsupported
        }
    }

    public func configVersionETag() async throws -> String? {
        do {
            return try await exchange.send(builder.request(.get, "v8/management/config/config-version")).header("ETag")
        } catch APIError.notFound(_) {
            return nil
        }
    }

    public func setRoutingStrategy(_ strategy: String, ifMatch etag: String?) async throws {
        let body = try JSONEncoder().encode(strategy)
        let conditional = etag.map { ["If-Match": $0] } ?? [:]
        _ = try await exchange.send(builder.request(.put, "v8/management/config/routing/strategy", json: body, extraHeaders: conditional))
    }

    public func upstreamKeyCounters() async throws -> [ProviderKeyCounters] {
        let response = try await exchange.send(builder.request(.get, "v8/management/observability/usage/api-keys"))
        do {
            return try APIKeyUsageReducer.reduce(response.body)
        } catch {
            throw APIError.decoding("api-key usage")
        }
    }

    public func clientKeyPolicyCount() async throws -> Int? {
        do {
            let response = try await exchange.send(builder.request(.get, "v8/management/client-key-policies"))
            return try exchange.decode([ClientKeyPolicy].self, from: response).count
        } catch APIError.notFound(_) {
            return nil
        }
    }

    public func credentialModels(name: String) async throws -> [ModelInfo] {
        let response = try await exchange.send(builder.request(.get, "v8/management/credentials/models", query: [URLQueryItem(name: "name", value: name)]))
        return try exchange.decode(CredentialModelsResponse.self, from: response).models ?? []
    }

    public func clientKeyUsage(since from: Date? = nil) async throws -> ClientKeyUsageReport? {
        let query = from.map { [URLQueryItem(name: "from", value: WireDate.format($0))] } ?? []
        do {
            let response = try await exchange.send(builder.request(.get, "v8/management/usage/client-keys", query: query))
            return try exchange.decode(ClientKeyUsageReport.self, from: response)
        } catch APIError.notFound(_) {
            return nil
        }
    }
}

public struct ClientKeyClient: Sendable {
    private let builder: RequestBuilder
    private var exchange: Exchange

    public init(baseURL: URL, clientKey: String, transport: any HTTPTransport) {
        builder = RequestBuilder(baseURL: baseURL, credential: clientKey)
        exchange = Exchange(transport: transport)
    }

    public func sending(under ticket: SendGate.Ticket) -> ClientKeyClient {
        var gated = self
        gated.exchange.ticket = ticket
        return gated
    }

    public func models() async throws -> [ModelInfo] {
        let response = try await exchange.send(builder.request(.get, "v1/models"))
        return try exchange.decode(ModelList.self, from: response).data
    }

    public func fleetLimits() async throws -> FleetLimits? {
        do {
            let response = try await exchange.send(builder.request(.get, "v1/fleet/limits"))
            return try exchange.decode(FleetLimits.self, from: response)
        } catch APIError.notFound(_) {
            return nil
        }
    }
}
