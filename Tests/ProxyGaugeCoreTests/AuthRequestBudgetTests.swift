import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("A rejected key costs one management request per refresh")
struct AuthRequestBudgetTests {
    static let rejections: [HTTPResponse] = [
        .json(#"{"error":"invalid management key"}"#, status: 401),
        .json(#"{"error":"IP banned due to too many failed attempts. Try again in 29m12s"}"#, status: 403)
    ]

    static let scopes: [RefreshScope] = [.accounts, .usage, .models, .settings, .limits, .accountModels("account.json")]

    func load(_ scope: RefreshScope, rejection: HTTPResponse) async -> (error: (any Error)?, managementRequests: Int) {
        let stub = StubTransport { _ in rejection }
        let management = ManagementClient(baseURL: testBaseURL, managementKey: "rotated", transport: stub)
        let client = ClientKeyClient(baseURL: testBaseURL, clientKey: "rotated", transport: stub)
        do {
            _ = try await ScopeLoader.load(scope, authMode: .management, management: management, client: client)
            return (nil, stub.managementRequestCount)
        } catch {
            return (error, stub.managementRequestCount)
        }
    }

    @Test(arguments: scopes, rejections)
    func everyScopeStopsAfterTheFirstRejection(scope: RefreshScope, rejection: HTTPResponse) async {
        let result = await load(scope, rejection: rejection)
        #expect(result.managementRequests == 1)
        #expect((result.error as? APIError)?.isAuthenticationFailure == true)
    }

    @Test func keyRevokedAfterTheAccountListStopsBeforeTheCounters() async {
        let stub = StubTransport { request in
            request.url.path() == "/v8/management/credentials"
                ? .json(#"{"files":[]}"#)
                : .json(#"{"error":"invalid management key"}"#, status: 401)
        }
        await #expect(throws: APIError.unauthorized("invalid management key")) {
            try await ScopeLoader.accounts(ManagementClient(baseURL: testBaseURL, managementKey: "k", transport: stub))
        }
        #expect(stub.managementRequestCount == 2)
    }

    @Test func countersFailingForOtherReasonsKeepTheAccountList() async throws {
        let stub = StubTransport { request in
            request.url.path() == "/v8/management/credentials"
                ? .json(#"{"files":[]}"#)
                : .json(#"{"error":"core manager unavailable"}"#, status: 503)
        }
        let list = try await ScopeLoader.accounts(ManagementClient(baseURL: testBaseURL, managementKey: "k", transport: stub))
        #expect(list.credentials.value.files.isEmpty)
        guard case .failure(.server(status: 503, _)) = list.keyCounters else {
            Issue.record("Expected the counter failure to be kept, got \(list.keyCounters)")
            return
        }
    }

    @Test func settingsPropagateARejectedPolicyRead() async {
        let stub = StubTransport { request in
            request.url.path().hasSuffix("/routing/strategy")
                ? .json(#""round-robin""#, headers: ["ETag": #""v1""#])
                : .json(#"{"error":"invalid management key"}"#, status: 401)
        }
        let management = ManagementClient(baseURL: testBaseURL, managementKey: "k", transport: stub)
        await #expect(throws: APIError.unauthorized("invalid management key")) {
            try await ScopeLoader.load(.settings, authMode: .management, management: management, client: ClientKeyClient(baseURL: testBaseURL, clientKey: "k", transport: stub))
        }
    }

    @Test func modelCatalogSendsOneRequestWhenEveryAccountIsRejected() async {
        let stub = StubTransport { _ in .json(#"{"error":"invalid management key"}"#, status: 401) }
        let credentials = (1...8).map { Credential(name: "account-\($0).json", authIndex: "\($0)", provider: "claude") }
        await #expect(throws: APIError.unauthorized("invalid management key")) {
            try await ModelCatalog.load(from: ManagementClient(baseURL: testBaseURL, managementKey: "k", transport: stub), credentials: credentials)
        }
        #expect(stub.managementRequestCount == 1)
    }

    @Test func modelCatalogStopsQueueingAfterALaterRejection() async {
        let stub = StubTransport { request in
            let name = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
            return name == "account-1.json" ? .json(#"{"models":[{"id":"m"}]}"#) : .json(#"{"error":"invalid management key"}"#, status: 401)
        }
        let credentials = (1...12).map { Credential(name: "account-\($0).json", authIndex: "\($0)", provider: "claude") }
        await #expect(throws: APIError.unauthorized("invalid management key")) {
            try await ModelCatalog.load(from: ManagementClient(baseURL: testBaseURL, managementKey: "k", transport: stub), credentials: credentials)
        }
        #expect(stub.managementRequestCount <= 1 + ModelCatalog.maximumConcurrentRequests)
    }

    @Test func clientKeyScopesStopAfterTheFirstRejection() async {
        for scope in [RefreshScope.models, .limits] {
            let stub = StubTransport { _ in .json(#"{"error":"unauthorized"}"#, status: 401) }
            let management = ManagementClient(baseURL: testBaseURL, managementKey: "k", transport: stub)
            let client = ClientKeyClient(baseURL: testBaseURL, clientKey: "k", transport: stub)
            await #expect(throws: APIError.unauthorized("unauthorized")) {
                try await ScopeLoader.load(scope, authMode: .clientKey, management: management, client: client)
            }
            #expect(stub.requests.count == 1)
        }
    }
}

@Suite("IP ban responses")
struct IPBanTests {
    @Test func banIsDetectedWithItsRetryTime() {
        let received = Date(timeIntervalSince1970: 1_800_000_000)
        let response = HTTPResponse.json(#"{"error":"IP banned due to too many failed attempts. Try again in 29m12s"}"#, status: 403)
        let error = APIError.from(response, receivedAt: received)
        #expect(error == .ipBanned(retryAt: received.addingTimeInterval(29 * 60 + 12)))
        #expect(error.isAuthenticationFailure)
    }

    @Test(arguments: [("30m0s", 1800.0), ("1h2m3s", 3723.0), ("45s", 45.0), ("1.5s", 1.5), ("250ms", 0.25)])
    func goDurationsAreParsed(text: String, seconds: Double) {
        #expect(GoDuration.seconds(in: text) == seconds)
    }

    @Test func banWithoutADurationStillCountsAsABan() {
        let response = HTTPResponse.json(#"{"error":"IP banned due to too many failed attempts. Try again later"}"#, status: 403)
        #expect(APIError.from(response) == .ipBanned(retryAt: nil))
    }

    @Test func otherForbiddenResponsesStayForbidden() {
        #expect(APIError.from(.json(#"{"error":"remote management disabled"}"#, status: 403)) == .forbidden("remote management disabled"))
    }
}
