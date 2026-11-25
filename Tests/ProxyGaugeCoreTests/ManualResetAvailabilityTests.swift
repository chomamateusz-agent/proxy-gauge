import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Provider reset inventory")
struct ManualResetAvailabilityTests {
    @Test(arguments: [
        #"{"id":"grant_a","resets_left":4,"resets_total":4,"ends_at":"2026-11-15T10:00:00"}"#,
        #"{"id":"grant_a","resets_left":4,"resets_total":4,"starts_at":"2026-11-15T10:00:01"}"#,
        #"{"id":"grant_a","resets_left":4,"resets_total":4,"paused":true}"#
    ])
    func unusableClaudeGrantsAreNotCounted(_ grant: String) throws {
        let block = try JSONSerialization.jsonObject(with: Data("{\"eligible\":true,\"grants\":[\(grant)]}".utf8))
        let reset = try #require(try ClaudeAdapter.resets(block, at: date("2026-11-15T10:00:00Z")))
        #expect(reset.remaining == 0)
        #expect(reset.expiresAt == nil)
    }

    @Test func duplicateOrUnusableGrantMetadataDoesNotInventResets() throws {
        let now = date("2026-11-15T10:00:00Z")
        let grant = ["id": "grant_a", "resets_left": 2, "resets_total": 2] as [String: Any]
        let duplicate = try ClaudeAdapter.resets(["eligible": true, "grants": [grant, grant]], at: now)
        #expect(duplicate == nil)
        var malformed = grant
        malformed["ends_at"] = "unknown"
        let unknown = try ClaudeAdapter.resets(["eligible": true, "grants": [malformed]], at: now)
        #expect(unknown == nil)
    }

    @Test func grantAvailabilityIsReevaluatedAfterStorage() throws {
        let now = date("2026-11-15T10:00:00Z")
        let block = try JSONSerialization.jsonObject(with: Data(#"{"eligible":true,"grants":[{"id":"grant_a","resets_left":1,"resets_total":1,"starts_at":"2026-11-15T10:00:00","ends_at":"2026-11-15T11:00:00Z"},{"id":"grant_b","resets_left":2,"resets_total":2,"starts_at":"2026-11-15T11:00:00","ends_at":"2026-11-15T12:00:00Z"}]}"#.utf8))
        let resets = try #require(try ClaudeAdapter.resets(block, at: now))
        let saved = try JSONDecoder.wire().decode(ManualResets.self, from: JSONEncoder.wire().encode(resets))
        #expect(saved.remaining == 1)
        #expect(saved.usable(at: now.addingTimeInterval(3600)).remaining == 2)
        #expect(saved.usable(at: now.addingTimeInterval(7200)).remaining == 0)
    }

    @Test func creditsRequireAvailableStatusAndFutureExpiry() throws {
        let inventory = try JSONSerialization.jsonObject(with: Data(#"{"available_count":4,"credits":[{"reset_type":"codex_rate_limits","status":"available","expires_at":"2026-11-15T10:00:00Z"},{"reset_type":"codex_rate_limits","status":"used","expires_at":"2026-11-16T10:00:00Z"},{"reset_type":"codex_rate_limits","status":"available"},{"reset_type":"codex_rate_limits","status":"available","expires_at":"2026-11-16T10:00:00Z"}]}"#.utf8))
        let now = date("2026-11-15T10:00:00Z")
        let resets = try #require(try CodexAdapter.resetCredits(inventory, at: now))
        #expect(resets.remaining == 1)
        #expect(resets.usable(at: now.addingTimeInterval(86_400)).remaining == 0)
    }

    @Test func anOldInventoryRemainsOldWhenOnlyUsageIsRefreshed() throws {
        let now = date("2026-11-15T10:00:00Z")
        let past = now.addingTimeInterval(-3600)
        let previous = ActiveQuota(credentialID: "a", provider: "claude", observedAt: past, resets: ManualResets(remaining: 2))
        let newestUsage = ActiveQuota(credentialID: "a", provider: "claude", observedAt: now, windows: [QuotaBar(id: "session_5h", usedPercent: 5)])
        let merged = newestUsage.superseding(previous, read: [.windows])
        let check = ProviderCheck(try JSONDecoder.wire().decode(ActiveQuota.self, from: JSONEncoder.wire().encode(merged)))
        var account = AccountSummary(id: "a", provider: "claude", label: "A", state: .active, bars: [], providerCheck: check)
        account.accountsLoadedAt = now.addingTimeInterval(-60)
        #expect(check.observedAt == now)
        #expect(check.sampledAt(for: .resets) == past)
        #expect(check.resets?.remaining == 2)
        #expect(account.cardResets(at: now) == nil)
        account.accountsLoadedAt = past
        #expect(account.cardResets(at: now)?.remaining == 2)
    }
}
