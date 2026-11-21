import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Card order, pool segments and the Lab switch")
struct AccountOrderTests {
    let now = date("2026-11-21T10:00:00Z")

    func account(
        _ id: String,
        provider: String = "claude",
        state: CredentialState = .active,
        weekly: Double? = 40,
        weeklyResetHours: Double = 48,
        session: Double? = 20,
        blockedForHours: Double? = nil,
        requiresSignIn: Bool = false
    ) -> AccountSummary {
        var bars: [QuotaBar] = []
        if let weekly { bars.append(QuotaBar(id: "weekly_all", usedPercent: weekly, resetsAt: now.addingTimeInterval(weeklyResetHours * 3_600), sampledAt: now.addingTimeInterval(-60))) }
        if let session { bars.append(QuotaBar(id: "session_5h", usedPercent: session, resetsAt: now.addingTimeInterval(3_600), sampledAt: now.addingTimeInterval(-60))) }
        let blockedUntil = blockedForHours.map { now.addingTimeInterval($0 * 3_600) }
        return AccountSummary(
            id: id,
            provider: provider,
            label: id + "@example.com",
            state: blockedUntil != nil ? .cooldown : state,
            bars: bars,
            blockedUntil: blockedUntil,
            requiresSignIn: requiresSignIn
        )
    }

    @Test func stockOrderPutsUsableFirstThenSoonestBackThenAttention() {
        let accounts = [
            account("disabled", state: .disabled),
            account("back-late", blockedForHours: 30),
            account("usable-a"),
            account("sign-in", state: .error, requiresSignIn: true),
            account("back-soon", blockedForHours: 2),
            account("usable-b"),
            account("error", state: .error)
        ]
        let ordered = AccountOrder.ordered(accounts, mode: .stock, now: now)
        #expect(ordered.map(\.id) == ["usable-a", "usable-b", "back-soon", "back-late", "disabled", "sign-in", "error"])
        #expect(ordered.map(\.section) == [.usable, .usable, .comingBack, .comingBack, .needsAttention, .needsAttention, .needsAttention])
        #expect(ordered.allSatisfy { $0.badge == nil })
    }

    @Test func anAccountAtItsWeeklyLimitComesBackAtTheReset() {
        let limited = account("limited", weekly: 100, weeklyResetHours: 5)
        #expect(AccountOrder.section(of: limited, at: now) == .comingBack)
        let ordered = AccountOrder.stock([account("cooling", blockedForHours: 10), limited], now: now)
        #expect(ordered.map(\.id) == ["limited", "cooling"])
    }

    @Test func routerModeRanksByTheSelectorAndBadgesEachCard() {
        let accounts = [
            account("late", weekly: 10, weeklyResetHours: 120),
            account("soon", weekly: 60, weeklyResetHours: 20),
            account("capped", weekly: 5, weeklyResetHours: 10, session: 97),
            account("cooling", blockedForHours: 3)
        ]
        let ordered = AccountOrder.ordered(accounts, mode: .router(RouterSettings(strategy: "use-or-lose")), now: now)
        #expect(ordered.map(\.id) == ["soon", "late", "capped", "cooling"])
        #expect(ordered.map(\.badge) == [.next, .position(2), .shortWindowCap, .coolingDown])
    }

    @Test func routerModeWithAnotherStrategyKeepsListOrder() {
        let accounts = [account("b", weekly: 10, weeklyResetHours: 120), account("a", weekly: 60, weeklyResetHours: 20)]
        let ordered = AccountOrder.ordered(accounts, mode: .router(.defaults), now: now)
        #expect(ordered.map(\.id) == ["b", "a"])
        #expect(ordered.allSatisfy { $0.badge == .listOrder })
    }

    @Test func routerReadingsComeFromTheAccountWindows() throws {
        var codex = account("codex", provider: "codex", weekly: 30, session: 50)
        codex.creditsBalance = 12
        let readings = try #require(AccountOrder.routerReadings(codex, now: now))
        #expect(readings.weekly?.usedPercent == 30)
        #expect(readings.short?.usedPercent == 50)
        #expect(readings.creditsAvailable)
        #expect(readings.observedAt == now.addingTimeInterval(-60))
        #expect(AccountOrder.routerReadings(account("x", provider: "xai"), now: now) == nil)
        #expect(AccountOrder.routerReadings(account("empty", weekly: nil, session: nil), now: now) == nil)
        let rejected = AccountSummary(id: "r", provider: "claude", label: "r", state: .active, bars: [QuotaBar(id: "weekly_all", usedPercent: nil, status: "rejected", resetsAt: now.addingTimeInterval(3_600))])
        #expect(AccountOrder.routerReadings(rejected, now: now)?.weekly?.usedPercent == 100)
    }

    @Test func outOfRotationFollowsEndDisabledAndCooldown() {
        var ended = account("ended")
        ended.endsAt = now.addingTimeInterval(-60)
        var flagged = account("flagged")
        flagged.hasEnded = true
        #expect(AccountOrder.outOfRotation(ended, now: now) == .ended)
        #expect(AccountOrder.outOfRotation(flagged, now: now) == .ended)
        #expect(AccountOrder.outOfRotation(account("d", state: .disabled), now: now) == .disabled)
        #expect(AccountOrder.outOfRotation(account("c", blockedForHours: 1), now: now) == .cooling)
        #expect(AccountOrder.outOfRotation(account("limited", weekly: 100), now: now) == nil)
        #expect(AccountOrder.outOfRotation(account("ok"), now: now) == nil)
    }

    @Test func credentialEndDatesAreDecodedFromTheForkFields() throws {
        let json = #"{"files":[{"id":"a.json","provider":"claude","priority":3,"fleet_ends_at":"2026-12-01T00:00:00Z","fleet_ended":false}]}"#
        let list = try JSONDecoder.wire().decode(CredentialList.self, from: Data(json.utf8))
        let summary = AccountSummary(credential: try #require(list.files.first), now: now)
        #expect(summary.priority == 3)
        #expect(summary.endsAt == date("2026-12-01T00:00:00Z"))
        #expect(!summary.hasEnded)
    }

    @Test func labShowsOnlyForForkServers() {
        #expect(ServerLab.isFleetFork(version: "v6.9.30-fleet.4", fleetLimitsAnswered: false))
        #expect(ServerLab.isFleetFork(version: "8.0.69", fleetLimitsAnswered: true))
        #expect(!ServerLab.isFleetFork(version: "8.0.69", fleetLimitsAnswered: false))
        #expect(!ServerLab.isFleetFork(version: nil, fleetLimitsAnswered: false))
        #expect(ServerLab.routerOrderDefault)
        let id = UUID()
        #expect(ServerLab.routerOrderKey(serverID: id) != ServerLab.routerOrderKey(serverID: UUID()))
    }

    @Test func segmentsFollowCardOrderAndMarkIdleBlockedLeftOutAndDisabled() throws {
        let idle = AccountSummary(id: "idle", provider: "claude", label: "idle", state: .active, bars: [QuotaBar(id: "weekly_all", usedPercent: 10)])
        let idleCooling = AccountSummary(id: "idle-cooling", provider: "claude", label: "idle-cooling", state: .cooldown, bars: [QuotaBar(id: "weekly_all", usedPercent: 10)], blockedUntil: now.addingTimeInterval(3_600))
        let noData = AccountSummary(id: "no-data", provider: "claude", label: "no-data", state: .active, bars: [])
        let disabled = account("disabled", state: .disabled)
        let running = account("running", session: 25)
        let accounts = [idle, idleCooling, noData, disabled, running]
        let pool = try #require(PooledCapacity.pools(accounts.map(\.poolAccount), now: now).first)
        let overview = ProviderOverview(pool: pool, accounts: accounts, now: now)
        let segments = overview.segments("session_5h", order: ["running", "idle-cooling", "idle"])
        #expect(segments.map(\.id) == ["running", "idle-cooling", "idle", "disabled", "no-data"])
        #expect(segments.map(\.kind) == [.counted, .idle, .idle, .disabled, .leftOut])
        #expect(segments.map(\.remainingPercent) == [75, 100, 100, 0, 0])
        #expect(segments.map(\.isBlocked) == [false, true, false, false, false])
        let session = try #require(pool.window(.session5h))
        #expect(session.accountsCountedAsFull == 2)
        #expect(session.accountsLeftOut == 1)
        #expect(session.capacityPercent == 300)
        #expect(session.remainingPercent == 275)
        #expect(session.usablePercent == 175)
    }

    @Test func chipsSplitSignInFromOtherErrors() throws {
        let accounts = [account("ok"), account("sign-in", state: .error, requiresSignIn: true), account("error", state: .error), account("off", state: .disabled)]
        let pool = try #require(PooledCapacity.pools(accounts.map(\.poolAccount), now: now).first)
        let overview = ProviderOverview(pool: pool, accounts: accounts, now: now)
        #expect(overview.chips == [
            StatusChip(kind: .state(.active), count: 1),
            StatusChip(kind: .state(.disabled), count: 1),
            StatusChip(kind: .state(.error), count: 1),
            StatusChip(kind: .needsSignIn, count: 1)
        ])
    }

    @Test func resetsListTheGainOfEveryUpcomingWindow() {
        let summary = account("a", weekly: 26, weeklyResetHours: 50, session: 98)
        let resets = summary.resets(at: now)
        #expect(resets.map(\.barID) == ["session_5h", "weekly_all"])
        #expect(resets.map(\.gainAtReset) == [98, 26])
        #expect(resets.map(\.remainingPercent) == [2, 74])
        #expect(summary.nextReset(after: now) == now.addingTimeInterval(3_600))
    }

    @Test func resetsListTheIdleFiveHourWindowThatStartsOnFirstUse() {
        let idle = AccountSummary(id: "i", provider: "claude", label: "i", state: .active, bars: [
            QuotaBar(id: "weekly_all", usedPercent: 30, resetsAt: now.addingTimeInterval(86_400 * 4))
        ])
        let resets = idle.resets(at: now)
        #expect(resets.map(\.barID) == ["session_5h", "weekly_all"])
        #expect(resets.map(\.startsOnFirstUse) == [true, false])
        #expect(resets.first?.remainingPercent == 100)
        #expect(resets.first?.gainAtReset == nil)
    }

    @Test func comebackGainsSayWhatTheBlockedAccountBringsBack() {
        let cooling = AccountSummary(id: "c", provider: "claude", label: "c", state: .cooldown, bars: [
            QuotaBar(id: "weekly_all", usedPercent: 30, resetsAt: now.addingTimeInterval(86_400 * 4)),
            QuotaBar(id: "weekly_fable", usedPercent: 56, resetsAt: now.addingTimeInterval(86_400 * 4))
        ], blockedUntil: now.addingTimeInterval(7_200))
        let gains = cooling.comebackGains(at: now)
        #expect(gains == [
            Comeback.Gain(barID: "session_5h", percent: 100),
            Comeback.Gain(barID: "weekly_all", percent: 70),
            Comeback.Gain(barID: "weekly_fable", percent: 44)
        ])
        #expect(cooling.cardBars(at: now).map(\.id) == ["session_5h", "weekly_all", "weekly_fable"])
        #expect(account("usable").comebackGains(at: now).isEmpty)
    }

    @Test func forkServersLoadTheRouterSettingsWithTheAccounts() async throws {
        let transport = StubTransport { request in
            let path = request.url.path()
            var headers = ["X-CPA-VERSION": "v6.9.30-fleet.4"]
            headers["Content-Type"] = "application/json"
            switch path {
            case "/v8/management/credentials": return HTTPResponse(statusCode: 200, headers: headers, body: Data(#"{"files":[]}"#.utf8))
            case "/v8/management/observability/usage/api-keys": return HTTPResponse(statusCode: 200, headers: headers, body: Data("{}".utf8))
            case "/v8/management/config/routing/strategy": return HTTPResponse(statusCode: 200, headers: headers, body: Data(#""use-or-lose""#.utf8))
            case "/v8/management/config/routing/use-or-lose/short-window-cap-pct": return HTTPResponse(statusCode: 200, headers: headers, body: Data("90".utf8))
            default: return HTTPResponse(statusCode: 404, body: Data(#"{"error":"not_found"}"#.utf8))
            }
        }
        let client = ManagementClient(baseURL: URL(string: "https://proxy.invalid")!, managementKey: "test", transport: transport)
        let list = try await ScopeLoader.accounts(client)
        #expect(list.routerSettings == RouterSettings(strategy: "use-or-lose", shortWindowCapPercent: 90, drainEndingCredentials: true))
        #expect(transport.requests.allSatisfy { $0.method == .get })
    }

    @Test func accountsLoadsSkipTheRouterSettingsOnceTheSessionHasThem() async throws {
        let transport = StubTransport { request in
            let headers = ["X-CPA-VERSION": "v6.9.30-fleet.4", "Content-Type": "application/json"]
            switch request.url.path() {
            case "/v8/management/credentials": return HTTPResponse(statusCode: 200, headers: headers, body: Data(#"{"files":[]}"#.utf8))
            case "/v8/management/observability/usage/api-keys": return HTTPResponse(statusCode: 200, headers: headers, body: Data("{}".utf8))
            default: return HTTPResponse(statusCode: 404, body: Data())
            }
        }
        let client = ManagementClient(baseURL: URL(string: "https://proxy.invalid")!, managementKey: "test", transport: transport)
        let list = try await ScopeLoader.accounts(client, readsRouterSettings: false)
        #expect(list.routerSettings == nil)
        #expect(transport.requests.count == 2)
    }

    @Test func settingsLoadsReReadTheRouterSettingsWithTheStrategyAlreadyRead() async throws {
        let transport = StubTransport { request in
            switch request.url.path() {
            case "/v8/management/config/routing/strategy": return .json(#""use-or-lose""#, headers: ["ETag": #""v1""#])
            case "/v8/management/config/routing/use-or-lose/drain-ending-credentials": return .json("false")
            default: return HTTPResponse(statusCode: 404, body: Data(#"{"error":"not_found"}"#.utf8))
            }
        }
        let management = ManagementClient(baseURL: URL(string: "https://proxy.invalid")!, managementKey: "test", transport: transport)
        let client = ClientKeyClient(baseURL: URL(string: "https://proxy.invalid")!, clientKey: "k", transport: transport)
        let published = PublishedStages()
        try await ScopeLoader.load(.settings, authMode: .management, management: management, client: client, readsRouterSettings: true) { await published.append($0) }
        let settings = await published.routerSettings
        #expect(settings == RouterSettings(strategy: "use-or-lose", drainEndingCredentials: false))
        #expect(transport.requests.count { $0.url.path().hasSuffix("/routing/strategy") } == 1)
        #expect(transport.requests.allSatisfy { $0.method == .get })
    }

    @Test func stockServersAreNotAskedForRouterSettings() async throws {
        let transport = StubTransport { request in
            let headers = ["X-CPA-VERSION": "8.0.69", "Content-Type": "application/json"]
            switch request.url.path() {
            case "/v8/management/credentials": return HTTPResponse(statusCode: 200, headers: headers, body: Data(#"{"files":[]}"#.utf8))
            case "/v8/management/observability/usage/api-keys": return HTTPResponse(statusCode: 200, headers: headers, body: Data("{}".utf8))
            default: return HTTPResponse(statusCode: 404, body: Data())
            }
        }
        let client = ManagementClient(baseURL: URL(string: "https://proxy.invalid")!, managementKey: "test", transport: transport)
        let list = try await ScopeLoader.accounts(client)
        #expect(list.routerSettings == nil)
        #expect(!transport.requests.contains { $0.url.path().contains("config/routing") })
    }
}

@Suite("Freshness header states")
struct FreshnessTests {
    let refreshed = date("2026-11-21T09:25:00Z")
    let saved = date("2026-11-21T07:00:00Z")

    @Test func freshAfterALoad() {
        #expect(Freshness(failed: false, loaded: true, lastRefresh: refreshed, savedAt: nil) == .fresh(refreshed))
    }

    @Test func savedDataBeforeTheServerAnswers() {
        #expect(Freshness(failed: false, loaded: false, lastRefresh: nil, savedAt: saved) == .saved(saved))
    }

    @Test func notReachedKeepsTheTimeOfTheLastData() {
        #expect(Freshness(failed: true, loaded: false, lastRefresh: nil, savedAt: saved) == .notReached(saved))
        #expect(Freshness(failed: true, loaded: true, lastRefresh: refreshed, savedAt: nil) == .notReached(refreshed))
        #expect(Freshness(failed: true, loaded: false, lastRefresh: nil, savedAt: nil) == .notReached(nil))
    }

    @Test func notRefreshedYetWithoutAnyData() {
        #expect(Freshness(failed: false, loaded: false, lastRefresh: nil, savedAt: nil) == .notRefreshed)
    }

    @Test func anAccountsRefreshDoesNotFreshenUsageOrModels() {
        let refreshed = RefreshScope.accounts.refreshedFreshnessKeys(authMode: .management)
        #expect(refreshed == [.accounts])
        #expect(!refreshed.contains(RefreshScope.usage.freshnessKey(authMode: .management)))
        #expect(!refreshed.contains(RefreshScope.models.freshnessKey(authMode: .management)))
    }

    @Test func usageAndModelsLoadsAlsoFreshenTheAccounts() {
        #expect(RefreshScope.usage.refreshedFreshnessKeys(authMode: .management) == [.usage, .accounts])
        #expect(RefreshScope.models.refreshedFreshnessKeys(authMode: .management) == [.models, .accounts])
    }

    @Test func accountDetailAndLimitsShareTheAccountsTime() {
        #expect(RefreshScope.accountDetail("a").freshnessKey(authMode: .management) == .accounts)
        #expect(RefreshScope.limits.freshnessKey(authMode: .management) == .accounts)
        #expect(RefreshScope.accountModels("a").refreshedFreshnessKeys(authMode: .management).isEmpty)
    }

    @Test func clientKeyScopesShareTheFleetLimitsTimeExceptModels() {
        #expect(RefreshScope.usage.freshnessKey(authMode: .clientKey) == .limits)
        #expect(RefreshScope.accounts.refreshedFreshnessKeys(authMode: .clientKey) == [.limits])
        #expect(RefreshScope.models.refreshedFreshnessKeys(authMode: .clientKey) == [.models])
    }
}

private actor PublishedStages {
    private var stages: [ScopeData] = []

    func append(_ stage: ScopeData) {
        stages.append(stage)
    }

    var routerSettings: RouterSettings? {
        stages.lazy.compactMap { if case .routerSettings(let settings) = $0 { settings } else { nil } }.first
    }
}
