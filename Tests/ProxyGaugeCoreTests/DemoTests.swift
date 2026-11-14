import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Demo server")
struct DemoTests {
    let profile = ServerProfile.demo()

    func management(_ transport: DemoTransport) -> ManagementClient {
        ManagementClient(baseURL: profile.baseURL, managementKey: DemoTransport.secret, transport: transport)
    }

    @Test func managementDataDecodesThroughTheRealClient() async throws {
        let transport = DemoTransport()
        let client = management(transport)
        let credentials = try await client.credentials()
        #expect(credentials.version?.version == "8.0.69")
        #expect(credentials.value.files.count == 7)
        let now = Date()
        let states = Set(credentials.value.files.map { $0.state(at: now) })
        #expect(states == Set(CredentialState.allCases))
        let headroom = HeadroomCalculator.fromCredentials(credentials.value.files, now: now)
        #expect(headroom.map(\.provider) == ["claude", "codex", "gemini-cli"])
        #expect(headroom[0].headroomPercent == 66)
        #expect(headroom[1].headroomPercent == 29)
        #expect(headroom[2].headroomPercent == nil)
        #expect(credentials.value.files.allSatisfy { $0.recentRequests.count == 20 })

        #expect(try await client.routingStrategy()?.strategy == "round-robin")
        #expect(try await client.clientKeyPolicyCount() == 3)
        #expect(try await client.upstreamKeyCounters().first?.keyCount == 1)
        #expect(try await client.credentialModels(name: "codex-main.json").count == 3)
        let usage = try #require(try await client.clientKeyUsage())
        #expect(TokenUsageSummary.from(usage).models.count == 4)
    }

    @Test func mutationsPersistWithinTheSession() async throws {
        let transport = DemoTransport()
        let client = management(transport)
        let team = try #require(try await client.credentials().value.files.first { $0.name == "claude-team.json" })
        #expect(team.state(at: Date()) == .cooldown)
        _ = try await client.resetCooldown(authIndex: try #require(team.authIndex))
        try await client.setDisabled(true, credential: team)
        let routing = try #require(try await client.routingStrategy())
        try await client.setRoutingStrategy("fill-first", ifMatch: routing.etag)
        await #expect(throws: APIError.preconditionFailed) { try await client.setRoutingStrategy("round-robin", ifMatch: routing.etag) }

        let after = try #require(try await client.credentials().value.files.first { $0.name == "claude-team.json" })
        #expect(after.state(at: Date()) == .disabled)
        #expect(try await client.routingStrategy()?.strategy == "fill-first")
        await #expect(throws: APIError.notFound("auth not found")) { try await client.resetCooldown(authIndex: "nope") }
    }

    @Test func clientKeyModeHasFleetLimits() async throws {
        let client = ClientKeyClient(baseURL: profile.baseURL, clientKey: DemoTransport.secret, transport: DemoTransport())
        #expect(try await client.models().isEmpty == false)
        let limits = try #require(try await client.fleetLimits())
        #expect(limits.object == "fleet.limits")
        #expect(limits.credentials.contains { $0.credits != nil })
        let headroom = HeadroomCalculator.fromFleet(limits)
        #expect(headroom.first { $0.provider == "claude" }?.headroomPercent == 66)
    }

    @Test func headroomLoaderWorksForBothModes() async throws {
        let transport = DemoTransport()
        let management = try await HeadroomLoader.load(profile: .demo(authMode: .management), secret: DemoTransport.secret, transport: transport)
        #expect(management.source == .passiveObservations)
        #expect(management.isDemo)
        #expect(management.lowestHeadroom?.provider == "codex")
        let fleet = try await HeadroomLoader.load(profile: .demo(authMode: .clientKey), secret: DemoTransport.secret, transport: transport)
        #expect(fleet.source == .fleetLimits)
    }

    @Test func clientModeWithoutFleetReportsUnavailable() async throws {
        let stub = StubTransport(routes: [:])
        let profile = ServerProfile(name: "stock", baseURL: testBaseURL, authMode: .clientKey)
        let snapshot = try await HeadroomLoader.load(profile: profile, secret: "k", transport: stub)
        #expect(snapshot.source == .unavailable)
        #expect(snapshot.providers.isEmpty)
    }

    @Test func unknownRoutesAreNotFound() async throws {
        let response = try await DemoTransport().send(HTTPRequest(url: profile.baseURL.appending(path: "v8/management/observability/usage/queue")))
        #expect(response.statusCode == 404)
    }
}
