import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Management client")
struct ManagementClientTests {
    let key = "test-management-key"

    @Test func credentialsRequestCarriesBearerAndReadsVersionHeaders() async throws {
        let stub = StubTransport(routes: ["GET /v8/management/credentials": try Fixture.response("auth-files-empty.json", headers: stockVersionHeaders)])
        let result = try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).credentials()
        #expect(result.value.files.isEmpty)
        #expect(result.version == ServerVersion(version: "8.0.69", commit: "f7ae8fee", buildDate: "2026-11-12T18:27:10Z"))
        let request = try #require(stub.requests.first)
        #expect(request.headers["Authorization"] == "Bearer \(key)")
        #expect(request.url.absoluteString == "http://192.168.1.20:8317/v8/management/credentials")
    }

    @Test func pathPrefixInBaseURLIsKept() async throws {
        let stub = StubTransport { request in
            #expect(request.url.path() == "/proxy/v8/management/credentials")
            return HTTPResponse.json(#"{"files":[]}"#)
        }
        let client = ManagementClient(baseURL: URL(string: "https://host.example/proxy")!, managementKey: key, transport: stub)
        _ = try await client.credentials()
    }

    @Test func unauthorizedMapsServerMessage() async throws {
        let stub = StubTransport(routes: ["GET /v8/management/credentials": try Fixture.response("management-key-missing.json", status: 401)])
        await #expect(throws: APIError.unauthorized("missing management key")) {
            try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).credentials()
        }
    }

    @Test func remoteManagementDisabledIsRecognised() async throws {
        let stub = StubTransport { _ in .json(#"{"error":"remote management disabled"}"#, status: 403) }
        do {
            _ = try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).credentials()
            Issue.record("Expected a failure")
        } catch let error as APIError {
            #expect(error.isRemoteManagementDisabled)
        }
    }

    @Test func plainTextNotFoundBodyIsTolerated() async throws {
        let stub = StubTransport(routes: [:])
        await #expect(throws: APIError.notFound("404 page not found")) {
            try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).credentials()
        }
    }

    @Test func setDisabledSendsNameIndexAndFlag() async throws {
        let stub = StubTransport { _ in .json(#"{"status":"ok","disabled":true}"#) }
        let credential = Credential(name: "account.json", authIndex: "opaque-1", provider: "claude")
        try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).setDisabled(true, credential: credential)
        let request = try #require(stub.requests.first)
        #expect(request.method == .patch)
        #expect(request.url.path() == "/v8/management/credentials/status")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(String(decoding: request.body ?? Data(), as: UTF8.self) == #"{"auth_index":"opaque-1","disabled":true,"name":"account.json"}"#)
    }

    @Test func setDisabledOnMissingAccountIsNotFound() async throws {
        let stub = StubTransport { _ in .json(#"{"error":"auth file not found"}"#, status: 404) }
        let credential = Credential(name: "missing.json", authIndex: nil, provider: "claude")
        await #expect(throws: APIError.notFound("auth file not found")) {
            try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).setDisabled(true, credential: credential)
        }
        #expect(String(decoding: stub.requests[0].body ?? Data(), as: UTF8.self) == #"{"disabled":true,"name":"missing.json"}"#)
    }

    @Test func cooldownResetToleratesNullModels() async throws {
        let stub = StubTransport { _ in .json(#"{"status":"ok","auth_index":"opaque-1","models":null}"#) }
        let result = try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).resetCooldown(authIndex: "opaque-1")
        #expect(result.models == nil)
        #expect(stub.requests[0].method == .post)
        #expect(stub.requests[0].url.path() == "/v8/management/routing/cooldown/reset")
        #expect(String(decoding: stub.requests[0].body ?? Data(), as: UTF8.self) == #"{"auth_index":"opaque-1"}"#)
    }

    @Test func routingStrategyReadsRawStringAndWritesJSONString() async throws {
        let stub = StubTransport { request in
            request.method == .get
                ? .json(#""round-robin""#, headers: ["ETag": #""abc""#])
                : .json(#"{"config-version":8,"status":"ok"}"#)
        }
        let client = ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub)
        let setting = try #require(try await client.routingStrategy())
        #expect(setting == RoutingStrategySetting(strategy: "round-robin", isExplicit: true, etag: #""abc""#))
        try await client.setRoutingStrategy("fill-first", ifMatch: setting.etag)
        #expect(stub.requests[1].method == .put)
        #expect(stub.requests[1].url.path() == "/v8/management/config/routing/strategy")
        #expect(stub.requests[1].headers["If-Match"] == #""abc""#)
        #expect(String(decoding: stub.requests[1].body ?? Data(), as: UTF8.self) == #""fill-first""#)
    }

    @Test func staleRoutingWriteIsAPreconditionFailure() async throws {
        let stub = StubTransport { request in
            let current = #""new""#
            if request.method == .get { return .json(#""fill-first""#, headers: ["ETag": current]) }
            guard request.headers["If-Match"] == current else {
                return .json(#"{"error":"precondition_failed"}"#, status: 412, headers: ["ETag": current])
            }
            return .json(#"{"config-version":8,"status":"ok"}"#)
        }
        let client = ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub)
        await #expect(throws: APIError.preconditionFailed) {
            try await client.setRoutingStrategy("round-robin", ifMatch: #""old""#)
        }
        let fresh = try #require(try await client.routingStrategy())
        try await client.setRoutingStrategy("round-robin", ifMatch: fresh.etag)
        #expect(stub.requests.count == 3)
    }

    @Test func absentRoutingLeafCarriesTheConfigVersion() async throws {
        let stub = StubTransport { request in
            request.url.path().hasSuffix("/config-version")
                ? .json("8", headers: ["ETag": #""file-v1""#])
                : .json(#"{"error":"not_found"}"#, status: 404)
        }
        let setting = try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).routingStrategy()
        #expect(setting == RoutingStrategySetting(strategy: "round-robin", isExplicit: false, etag: #""file-v1""#))
        #expect(stub.requests.map { $0.url.path() } == [
            "/v8/management/config/routing/strategy",
            "/v8/management/config/config-version",
            "/v8/management/config/routing/strategy"
        ])
    }

    @Test func routingSetWhileReadingTheVersionIsShownAsSet() async throws {
        let reads = Counter()
        let stub = StubTransport { request in
            if request.url.path().hasSuffix("/config-version") { return .json("8", headers: ["ETag": #""file-v2""#]) }
            return reads.next() == 1
                ? .json(#"{"error":"not_found"}"#, status: 404)
                : .json(#""fill-first""#, headers: ["ETag": #""file-v2""#])
        }
        let setting = try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).routingStrategy()
        #expect(setting == RoutingStrategySetting(strategy: "fill-first", isExplicit: true, etag: #""file-v2""#))
    }

    @Test func absentRoutingWithoutAConfigVersionHasNoETag() async throws {
        let stub = StubTransport { _ in .json(#"{"error":"not_found"}"#, status: 404) }
        let setting = try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).routingStrategy()
        #expect(setting == RoutingStrategySetting(strategy: "round-robin", isExplicit: false, etag: nil))
    }

    @Test func missingConfigRouteMeansRoutingIsUnsupported() async throws {
        let stub = StubTransport(routes: [:])
        #expect(try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).routingStrategy() == nil)
    }

    @Test func unconditionalRoutingWriteSendsNoIfMatch() async throws {
        let stub = StubTransport { _ in .json(#"{"config-version":8,"status":"ok"}"#) }
        try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).setRoutingStrategy("fill-first", ifMatch: nil)
        #expect(stub.requests[0].headers["If-Match"] == nil)
    }

    @Test func clientKeyPoliciesAreCountedWithoutKeyValues() async throws {
        let stub = StubTransport(routes: [
            "GET /v8/management/client-key-policies": .json(#"[{"index":0,"name":"laptop","has_policy":false,"models":[]},{"index":1,"name":"ci","has_policy":true,"models":["gpt-5"]}]"#)
        ])
        #expect(try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).clientKeyPolicyCount() == 2)
        #expect(stub.requests.map { $0.url.path() } == ["/v8/management/client-key-policies"])
    }

    @Test func stockServerDoesNotReportAClientKeyCount() async throws {
        let stub = StubTransport(routes: [:])
        #expect(try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).clientKeyPolicyCount() == nil)
        #expect(!stub.requests.contains { $0.url.path().contains("api-keys") })
    }

    @Test func credentialModelsEncodesName() async throws {
        let stub = StubTransport { _ in .json(#"{"models":[{"id":"gpt-5","display_name":"GPT-5","type":"chat","owned_by":"openai"}]}"#) }
        let models = try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).credentialModels(name: "a b.json")
        #expect(models.map(\.id) == ["gpt-5"])
        #expect(stub.requests[0].url.query() == "name=a%20b.json")
    }

    @Test func missingClientKeyUsageReportIsNil() async throws {
        let stub = StubTransport(routes: [:])
        #expect(try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).clientKeyUsage() == nil)
    }

    @Test(arguments: [URLError(.cancelled) as any Error, CancellationError() as any Error])
    func cancellationStaysTypedRegardlessOfLocale(failure: any Error) async throws {
        let stub = StubTransport { _ in throw failure }
        await #expect(throws: CancellationError.self) {
            try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).credentials()
        }
    }

    @Test func modelCatalogKeepsModelsWhenOneAccountFails() async throws {
        let stub = StubTransport { request in
            let name = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
            switch name {
            case "good.json": return .json(#"{"models":[{"id":"gpt-5"},{"id":"gpt-5-mini"}]}"#)
            case "other.json": return .json(#"{"models":[{"id":"gpt-5"}]}"#)
            default: return .json(#"{"error":"invalid name"}"#, status: 400)
            }
        }
        let credentials = [
            Credential(name: "good.json", authIndex: "1", provider: "openai"),
            Credential(name: "odd.json", authIndex: "2", provider: "claude"),
            Credential(name: "other.json", authIndex: "3", provider: "gemini-cli")
        ]
        let catalog = try await ModelCatalog.load(from: ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub), credentials: credentials)
        #expect(catalog.models.map(\.id) == ["gpt-5", "gpt-5-mini"])
        #expect(catalog.providers["gpt-5"] == ["openai", "gemini-cli"])
        #expect(catalog.failedAccounts == ["odd.json"])
    }

    @Test func transportFailuresBecomeTransportErrors() async throws {
        let stub = StubTransport { _ in throw URLError(.cannotConnectToHost) }
        await #expect {
            try await ManagementClient(baseURL: testBaseURL, managementKey: key, transport: stub).credentials()
        } throws: { error in
            if case .transport = error as? APIError { return true }
            return false
        }
    }
}

@Suite("Client-key client")
struct ClientKeyClientTests {
    @Test func modelsUseClientKey() async throws {
        let stub = StubTransport(routes: ["GET /v1/models": try Fixture.response("client-models-empty.json")])
        let models = try await ClientKeyClient(baseURL: testBaseURL, clientKey: "test-client-key", transport: stub).models()
        #expect(models.isEmpty)
        #expect(stub.requests[0].headers["Authorization"] == "Bearer test-client-key")
        #expect(stub.requests[0].headers["Anthropic-Version"] == nil)
    }

    @Test func stockServerHasNoFleetLimits() async throws {
        let stub = StubTransport(routes: [:])
        #expect(try await ClientKeyClient(baseURL: testBaseURL, clientKey: "k", transport: stub).fleetLimits() == nil)
    }

    @Test func fleetLimitsAuthFailureIsNotHidden() async throws {
        let stub = StubTransport { _ in .json(#"{"error":"unauthorized"}"#, status: 401) }
        await #expect(throws: APIError.unauthorized("unauthorized")) {
            try await ClientKeyClient(baseURL: testBaseURL, clientKey: "k", transport: stub).fleetLimits()
        }
    }
}

@Suite("Server probe")
struct ServerProbeTests {
    @Test func stockManagementServerReportsVersionAndFeatures() async throws {
        let stub = StubTransport(routes: [
            "GET /healthz": .json(#"{"status":"ok"}"#),
            "GET /v8/management/credentials": try Fixture.response("auth-files-empty.json", headers: stockVersionHeaders),
            "GET /v8/management/config/routing/strategy": .json(#""round-robin""#, headers: stockVersionHeaders)
        ])
        let report = await ServerProbe.run(baseURL: testBaseURL, authMode: .management, secret: "k", transport: stub)
        #expect(report.succeeded)
        #expect(report.version?.version == "8.0.69")
        #expect(report.accountCount == 0)
        #expect(report.features == [.health: true, .managementAPI: true, .routingSettings: true, .clientKeyUsageReport: false])
    }

    @Test func wrongKeyStopsAfterAuthentication() async throws {
        let stub = StubTransport(routes: [
            "GET /healthz": .json(#"{"status":"ok"}"#),
            "GET /v8/management/credentials": .json(#"{"error":"invalid management key"}"#, status: 401)
        ])
        let report = await ServerProbe.run(baseURL: testBaseURL, authMode: .management, secret: "k", transport: stub)
        #expect(report.failure == .unauthorized("invalid management key"))
        #expect(stub.requests.count == 2)
    }

    @Test func missingHealthEndpointDoesNotHideAWorkingAPI() async throws {
        let stub = StubTransport(routes: [
            "GET /v8/management/credentials": try Fixture.response("auth-files-empty.json", headers: stockVersionHeaders),
            "GET /v8/management/config/routing/strategy": .json(#"{"error":"not_found"}"#, status: 404)
        ])
        let report = await ServerProbe.run(baseURL: testBaseURL, authMode: .management, secret: "k", transport: stub)
        #expect(report.succeeded)
        #expect(report.features == [.health: false, .managementAPI: true, .routingSettings: true, .clientKeyUsageReport: false])
    }

    @Test func unreachableServerReportsTheTransportFailure() async throws {
        let stub = StubTransport { _ in throw URLError(.timedOut) }
        let report = await ServerProbe.run(baseURL: testBaseURL, authMode: .clientKey, secret: "k", transport: stub)
        #expect(report.features[.health] == false)
        #expect(report.features[.clientModels] == false)
        if case .transport = report.failure {} else { Issue.record("Expected a transport failure, got \(String(describing: report.failure))") }
    }

    @Test func stockClientKeyServerHasModelsOnly() async throws {
        let stub = StubTransport(routes: [
            "GET /healthz": .json(#"{"status":"ok"}"#),
            "GET /v1/models": try Fixture.response("client-models-empty.json")
        ])
        let report = await ServerProbe.run(baseURL: testBaseURL, authMode: .clientKey, secret: "k", transport: stub)
        #expect(report.succeeded)
        #expect(report.features == [.health: true, .clientModels: true, .fleetLimits: false])
        #expect(report.modelCount == 0)
    }
}

@Suite("Base URL validation")
struct BaseURLValidatorTests {
    @Test func trimsSlashAndKeepsExplicitScheme() throws {
        #expect(try BaseURLValidator.normalize(" 192.168.1.5:8317/ ").get().absoluteString == "http://192.168.1.5:8317")
        #expect(try BaseURLValidator.normalize("https://proxy.example.com/cpa/").get().absoluteString == "https://proxy.example.com/cpa")
        #expect(try BaseURLValidator.normalize("http://host.tailnet.ts.net:8317").get().absoluteString == "http://host.tailnet.ts.net:8317")
    }

    @Test(arguments: [
        ("proxy.example.com", "https://proxy.example.com"),
        ("proxy.example.com:8443/cpa", "https://proxy.example.com:8443/cpa"),
        ("host.tailnet.ts.net:8317", "https://host.tailnet.ts.net:8317"),
        ("192.168.1.10:8317", "http://192.168.1.10:8317"),
        ("100.101.102.103:8317", "http://100.101.102.103:8317"),
        ("localhost:8317", "http://localhost:8317"),
        ("nas:8317", "http://nas:8317"),
        ("mac-mini.local:8317", "http://mac-mini.local:8317"),
        ("[::1]:8317", "http://[::1]:8317")
    ])
    func schemelessAddressesPickHTTPSUnlessLocal(input: String, expected: String) throws {
        #expect(try BaseURLValidator.normalize(input).get().absoluteString == expected)
    }

    @Test(arguments: ["https://user:secret@proxy.example.com", "http://admin@192.168.1.2:8317", "user:secret@proxy.example.com"])
    func rejectsAddressesWithUserInfo(input: String) {
        #expect(throws: BaseURLValidator.Problem.hasUserInfo) { try BaseURLValidator.normalize(input).get() }
    }

    @Test func rejectsBadInput() {
        #expect(throws: BaseURLValidator.Problem.empty) { try BaseURLValidator.normalize("  ").get() }
        #expect(throws: BaseURLValidator.Problem.unsupportedScheme) { try BaseURLValidator.normalize("ftp://x").get() }
        #expect(throws: BaseURLValidator.Problem.hasQuery) { try BaseURLValidator.normalize("http://x?key=1").get() }
    }

    @Test(arguments: [
        ("localhost", true), ("mac-mini.local", true), ("nas", true), ("10.0.0.2", true), ("172.20.1.1", true),
        ("192.168.0.10", true), ("100.101.102.103", true), ("::1", true), ("8.8.8.8", false), ("host.tailnet.ts.net", false)
    ])
    func classifiesLocalHosts(host: String, local: Bool) {
        #expect(BaseURLValidator.isLocalHost(host) == local)
    }

    @Test func flagsPlainHTTPOutsideLocalNetwork() {
        #expect(ServerProfile(name: "a", baseURL: URL(string: "http://host.tailnet.ts.net:8317")!, authMode: .management).usesPlainHTTPOutsideLocalNetwork)
        #expect(!ServerProfile(name: "b", baseURL: URL(string: "http://192.168.1.2:8317")!, authMode: .management).usesPlainHTTPOutsideLocalNetwork)
        #expect(!ServerProfile(name: "c", baseURL: URL(string: "https://proxy.example.com")!, authMode: .management).usesPlainHTTPOutsideLocalNetwork)
    }
}
