import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Captured stock fixtures")
struct FixtureDecodingTests {
    @Test func emptyCredentialListKeepsFractionalObservationTime() throws {
        let list = try JSONDecoder.wire().decode(CredentialList.self, from: Fixture.data("auth-files-empty.json"))
        #expect(list.files.isEmpty)
        let observedAt = try #require(list.observedAt)
        #expect(abs(observedAt.timeIntervalSince(date("2026-11-13T23:10:00Z")) - 0.063357) < 0.001)
        #expect(list.total == nil)
    }

    @Test func emptyUpstreamKeyUsageReducesToNoProviders() throws {
        #expect(try APIKeyUsageReducer.reduce(Fixture.data("api-key-usage-empty.json")).isEmpty)
    }

    @Test func emptyClientModelList() throws {
        let list = try JSONDecoder.wire().decode(ModelList.self, from: Fixture.data("client-models-empty.json"))
        #expect(list.object == "list")
        #expect(list.data.isEmpty)
    }

    @Test func missingManagementKeyMapsToUnauthorized() throws {
        let error = APIError.from(try Fixture.response("management-key-missing.json", status: 401))
        #expect(error == .unauthorized("missing management key"))
    }

    @Test func routingSubtreeIsARawObject() throws {
        struct Routing: Decodable { var strategy: String }
        #expect(try JSONDecoder.wire().decode(Routing.self, from: Fixture.data("config-routing.json")).strategy == "round-robin")
    }
}

@Suite("Populated payloads")
struct PopulatedDecodingTests {
    static let credentialJSON = """
    {"observed_at":"2026-11-14T10:00:00Z","files":[
      {"id":"claude-a.json","auth_index":"7f2a","name":"claude-a.json","type":"claude","provider":"claude",
       "label":"A","status":"active","status_message":"","disabled":false,"unavailable":false,"runtime_only":false,
       "source":"file","size":1200,"success":120,"failed":3,"email":"a@example.com",
       "recent_requests":[{"time":"09:40-09:50","success":4,"failed":0},{"time":"09:50-10:00","success":6,"failed":1}],
       "quota":{"signals":{"Anthropic-Ratelimit-Unified-5h-Utilization":"0.25","Anthropic-Ratelimit-Unified-5h-Reset":"1794650400",
         "Anthropic-Ratelimit-Unified-5h-Status":"allowed","Anthropic-Ratelimit-Unified-7d-Utilization":"0.5"},
         "observed_at":"2026-11-14T09:58:00.5Z"},
       "model_quotas":{"claude-opus":{"signals":{"Anthropic-Ratelimit-Unified-7d_oi-Utilization":"0.9"},"observed_at":"2026-11-14T09:59:00Z"}},
       "cooldowns":[{"scope":"model","model_key":"claude-opus","reason":"quota","retry_at":"2026-11-14T11:00:00+01:00","remaining_seconds":0}],
       "requires_sign_in":false,"quota_blocked":false,"unknown_future_field":{"nested":[1,2,3]}},
      {"name":"disk-only.json","type":"codex","disabled":true,"cooldowns":null,"created_at":"not a date"}
    ]}
    """

    @Test func credentialFieldsAndUnknownsDecode() throws {
        let list = try JSONDecoder.wire().decode(CredentialList.self, from: Data(Self.credentialJSON.utf8))
        #expect(list.files.count == 2)
        let claude = list.files[0]
        #expect(claude.authIndex == "7f2a")
        #expect(claude.displayName == "a@example.com")
        #expect(claude.recentRequests.count == 2)
        #expect(claude.cooldowns?.first?.retryAt == date("2026-11-14T10:00:00Z"))
        #expect(claude.cooldowns?.first?.isCredentialWide == false)
        #expect(claude.observations.count == 2)

        let disk = list.files[1]
        #expect(disk.provider == "codex")
        #expect(disk.cooldowns == nil)
        #expect(disk.success == 0)
        #expect(disk.state(at: Date()) == .disabled)
    }

    @Test func credentialQuotaBarsComeFromFreshestObservations() throws {
        let list = try JSONDecoder.wire().decode(CredentialList.self, from: Data(Self.credentialJSON.utf8))
        let bars = Dictionary(uniqueKeysWithValues: list.files[0].quotaBars.map { ($0.id, $0) })
        #expect(bars["session_5h"]?.usedPercent == 25)
        #expect(bars["session_5h"]?.status == "allowed")
        #expect(bars["session_5h"]?.resetsAt == Date(timeIntervalSince1970: 1_794_650_400))
        #expect(bars["weekly_all"]?.usedPercent == 50)
        #expect(bars["weekly_fable"]?.usedPercent == 90)
        #expect(bars["weekly_fable"]?.sampledAt == date("2026-11-14T09:59:00Z"))
    }

    @Test func sourceDerivedEmptyFleetLimitsDecode() throws {
        let json = """
        {"object":"fleet.limits","generated_at":"2026-11-14T00:00:00Z","proxy_version":"8.0.42","client":{"name":null},
         "models":[],"exclusions":[],"credentials":[],"summary":{}}
        """
        let limits = try JSONDecoder.wire().decode(FleetLimits.self, from: Data(json.utf8))
        #expect(limits.object == "fleet.limits")
        #expect(limits.proxyVersion == "8.0.42")
        #expect(limits.clientName == nil)
        #expect(HeadroomCalculator.fromFleet(limits).isEmpty)
    }

    @Test func populatedFleetLimitsDecode() throws {
        let json = """
        {"object":"fleet.limits","generated_at":"2026-11-14T10:00:00Z","proxy_version":"8.0.42","client":{"name":"phone"},
         "models":[{"id":"gpt-5","providers":["codex"]}],
         "exclusions":[{"pattern":"claude-opus*","provider":"claude","source":"key-policy","until":null,"until_source":null}],
         "credentials":[
           {"label":"codex-1","provider":"codex","plan":"pro","state":"active",
            "bars":[{"id":"session_5h","percent":40.5,"status":null,"resets_at":"2026-11-14T12:00:00Z","sampled_at":"2026-11-14T09:59:00Z","reset_passed":false},
                    {"id":"weekly_all","percent":101,"status":null,"resets_at":"2026-11-14T09:00:00Z","sampled_at":"2026-11-13T09:59:00Z","reset_passed":true}],
            "credits":{"has_credits":null,"unlimited":null,"balance":null},"cooldowns":[]},
           {"label":"claude-1","provider":"claude","plan":null,"state":"cooldown","bars":[],
            "cooldowns":[{"scope":"credential","model":null,"reason":"quota","until":"2026-11-14T11:00:00Z","http_status":429}]}
         ],
         "summary":{"codex":{"usable_credentials":1,"bars":{"session_5h":{"percent":40.5,"resets_at":"2026-11-14T12:00:00Z"},"weekly_all":{"percent":0,"resets_at":null}}},
                    "claude":{"usable_credentials":0,"bars":{}}}}
        """
        let limits = try JSONDecoder.wire().decode(FleetLimits.self, from: Data(json.utf8))
        #expect(limits.credentials.count == 2)
        #expect(limits.credentials[0].credits?.balance == nil)
        #expect(limits.credentials[0].bars[1].quotaBar.usedPercent == 0)
        #expect(limits.credentials[1].credentialState == .cooldown)
        #expect(limits.credentials[1].credits == nil)
        #expect(limits.exclusions.first?.until == nil)

        let headroom = HeadroomCalculator.fromFleet(limits)
        #expect(headroom.map(\.provider) == ["claude", "codex"])
        #expect(headroom[0].headroomPercent == 0)
        #expect(headroom[1].headroomPercent == 59.5)
        #expect(headroom[1].limitingBarID == "session_5h")
    }

    @Test func clientKeyUsageReportAggregatesPerModel() throws {
        let json = """
        {"object":"fleet.client_key_usage","generated_at":"2026-11-14T10:00:00Z","from":"2026-11-07T10:00:00Z","to":"2026-11-14T10:00:00Z",
         "recording_since":null,"granularity":"hour","keys":[
          {"name":"laptop","created_at":null,"revoked":false,"requests":3,"failed_requests":1,"input_tokens":30,"output_tokens":10,
           "reasoning_tokens":0,"cache_read_tokens":5,"cache_creation_tokens":0,"total_tokens":45,
           "models":[{"provider":"claude","model":"sonnet","requests":3,"failed_requests":1,"input_tokens":30,"output_tokens":10,
             "reasoning_tokens":0,"cache_read_tokens":5,"cache_creation_tokens":0,"total_tokens":45}]},
          {"name":"ci","created_at":"2026-10-01T00:00:00.123456Z","revoked":true,"requests":2,"failed_requests":0,"input_tokens":20,
           "output_tokens":4,"reasoning_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0,"total_tokens":24,
           "models":[{"provider":"claude","model":"sonnet","requests":2,"failed_requests":0,"input_tokens":20,"output_tokens":4,
             "reasoning_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0,"total_tokens":24}]}]}
        """
        let report = try JSONDecoder.wire().decode(ClientKeyUsageReport.self, from: Data(json.utf8))
        let summary = TokenUsageSummary.from(report)
        #expect(summary.totals.requests == 5)
        #expect(summary.totals.totalTokens == 69)
        #expect(summary.models.count == 1)
        #expect(summary.models[0].counters.inputTokens == 50)
        #expect(report.recordingSince == nil)
    }

    @Test func upstreamKeyCountersNeverKeepKeyMaterial() throws {
        let json = #"{"OpenAI-Compatibility":{"https://a.example|sk-secret-1":{"success":3,"failed":1,"recent_requests":[]},"|sk-secret-2":{"success":2,"failed":0}}}"#
        let counters = try APIKeyUsageReducer.reduce(Data(json.utf8))
        #expect(counters == [ProviderKeyCounters(provider: "openai-compatibility", keyCount: 2, success: 5, failed: 1)])
        #expect(!String(describing: counters).contains("sk-secret"))
    }
}

@Suite("Wire dates")
struct WireDateTests {
    @Test(arguments: [
        ("2026-11-13T23:10:00Z", 0.0),
        ("2026-11-13T23:10:00.5Z", 0.5),
        ("2026-11-13T23:10:00.063357Z", 0.063357),
        ("2026-11-14T00:10:00+01:00", 0.0),
        ("2026-11-14T00:10:00.250+01:00", 0.25)
    ])
    func parsesRFC3339Variants(raw: String, fraction: Double) throws {
        let parsed = try #require(WireDate.parse(raw))
        let base = Date(timeIntervalSince1970: 1_794_611_400)
        #expect(abs(parsed.timeIntervalSince(base) - fraction) < 0.001)
    }

    @Test func rejectsGarbage() {
        #expect(WireDate.parse("") == nil)
        #expect(WireDate.parse("yesterday") == nil)
    }
}
