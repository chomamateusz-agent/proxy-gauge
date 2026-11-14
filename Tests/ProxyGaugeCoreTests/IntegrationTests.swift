import Foundation
import Testing
@testable import ProxyGaugeCore

enum IntegrationEnvironment {
    static let values = ProcessInfo.processInfo.environment
    static let isEnabled = values["PROXY_GAUGE_INTEGRATION_URL"] != nil

    static var baseURL: URL { URL(string: values["PROXY_GAUGE_INTEGRATION_URL"]!)! }

    static func secret(_ variable: String) throws -> String {
        let path = try #require(values[variable], "\(variable) is not set")
        return try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var managementKey: String { get throws { try secret("PROXY_GAUGE_INTEGRATION_KEY_FILE") } }
    static var clientKey: String { get throws { try secret("PROXY_GAUGE_INTEGRATION_CLIENT_KEY_FILE") } }
}

@Suite("Stock CLIProxyAPI integration", .serialized, .enabled(if: IntegrationEnvironment.isEnabled, "Set PROXY_GAUGE_INTEGRATION_URL; run make integration"))
struct IntegrationTests {
    let transport = URLSessionTransport(timeout: 10)

    func management() throws -> ManagementClient {
        ManagementClient(baseURL: IntegrationEnvironment.baseURL, managementKey: try IntegrationEnvironment.managementKey, transport: transport)
    }

    func client() throws -> ClientKeyClient {
        ClientKeyClient(baseURL: IntegrationEnvironment.baseURL, clientKey: try IntegrationEnvironment.clientKey, transport: transport)
    }

    @Test func managementProbeDetectsStockFeatures() async throws {
        let report = await ServerProbe.run(baseURL: IntegrationEnvironment.baseURL, authMode: .management, secret: try IntegrationEnvironment.managementKey, transport: transport)
        #expect(report.failure == nil)
        #expect(report.version?.version == "8.0.69")
        #expect(report.version?.commit == "f7ae8fee")
        #expect(report.accountCount == 0)
        #expect(report.features == [.health: true, .managementAPI: true, .routingSettings: true, .clientKeyUsageReport: false])
    }

    @Test func emptyServerReadsCleanly() async throws {
        let client = try management()
        let credentials = try await client.credentials()
        #expect(credentials.value.files.isEmpty)
        #expect(credentials.value.observedAt != nil)
        #expect(try await client.upstreamKeyCounters().isEmpty)
        #expect(try await client.clientKeyPolicyCount() == nil)
        #expect(try await client.configVersionETag() != nil)
        #expect(try await client.credentialModels(name: "missing.json").isEmpty)
        #expect(try await client.clientKeyUsage() == nil)
        let snapshot = try await HeadroomLoader.load(
            profile: ServerProfile(name: "stock", baseURL: IntegrationEnvironment.baseURL, authMode: .management),
            secret: try IntegrationEnvironment.managementKey,
            transport: transport
        )
        #expect(snapshot.providers.isEmpty)
    }

    @Test func routingStrategyRoundTripsWithETag() async throws {
        let client = try management()
        let original = try #require(try await client.routingStrategy())
        #expect(original.isExplicit)
        let etag = try #require(original.etag)
        let other = original.strategy == "fill-first" ? "round-robin" : "fill-first"
        try await client.setRoutingStrategy(other, ifMatch: etag)
        #expect(try await client.routingStrategy()?.strategy == other)
        await #expect(throws: APIError.preconditionFailed) {
            try await client.setRoutingStrategy(original.strategy, ifMatch: etag)
        }
        let current = try #require(try await client.routingStrategy())
        try await client.setRoutingStrategy(original.strategy, ifMatch: current.etag)
        #expect(try await client.routingStrategy()?.strategy == original.strategy)
    }

    func deleteConfigNode(_ path: String, ifMatch etag: String?) async throws {
        var request = URLRequest(url: IntegrationEnvironment.baseURL.appending(path: "v8/management/config/\(path)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(try IntegrationEnvironment.managementKey)", forHTTPHeaderField: "Authorization")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func absentRoutingStrategyIsWrittenAgainstTheConfigVersion() async throws {
        let client = try management()
        let original = try #require(try await client.routingStrategy())
        try await deleteConfigNode("routing/strategy", ifMatch: original.etag)
        let absent = try #require(try await client.routingStrategy())
        #expect(!absent.isExplicit)
        let version = try #require(absent.etag)
        try await client.setRoutingStrategy(original.strategy, ifMatch: version)
        let restored = try #require(try await client.routingStrategy())
        #expect(restored.isExplicit)
        #expect(restored.strategy == original.strategy)
        await #expect(throws: APIError.preconditionFailed) {
            try await client.setRoutingStrategy(original.strategy, ifMatch: version)
        }
    }

    @Test func mutationsOnUnknownAccountsAreNotFound() async throws {
        let client = try management()
        await #expect(throws: APIError.notFound("auth file not found")) {
            try await client.setDisabled(true, credential: Credential(name: "missing.json", authIndex: nil, provider: "claude"))
        }
        await #expect(throws: APIError.notFound("auth not found")) {
            try await client.resetCooldown(authIndex: "missing")
        }
    }

    @Test func wrongManagementKeyIsRejected() async throws {
        let client = ManagementClient(baseURL: IntegrationEnvironment.baseURL, managementKey: "not-the-key", transport: transport)
        await #expect(throws: APIError.unauthorized("invalid management key")) {
            try await client.credentials()
        }
    }

    @Test func clientKeyModeHasModelsButNoFleetLimits() async throws {
        let client = try client()
        _ = try await client.models()
        #expect(try await client.fleetLimits() == nil)
        let report = await ServerProbe.run(baseURL: IntegrationEnvironment.baseURL, authMode: .clientKey, secret: try IntegrationEnvironment.clientKey, transport: transport)
        #expect(report.failure == nil)
        #expect(report.features == [.health: true, .clientModels: true, .fleetLimits: false])
        let snapshot = try await HeadroomLoader.load(
            profile: ServerProfile(name: "stock", baseURL: IntegrationEnvironment.baseURL, authMode: .clientKey),
            secret: try IntegrationEnvironment.clientKey,
            transport: transport
        )
        #expect(snapshot.source == .unavailable)
    }

    @Test func clientKeyIsNotAManagementKey() async throws {
        let client = ManagementClient(baseURL: IntegrationEnvironment.baseURL, managementKey: try IntegrationEnvironment.clientKey, transport: transport)
        await #expect(throws: APIError.unauthorized("invalid management key")) {
            try await client.credentials()
        }
    }
}
