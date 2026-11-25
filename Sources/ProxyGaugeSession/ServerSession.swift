import Foundation
import Observation
import Synchronization
import ProxyGaugeCore
import ProxyGaugeStore

public enum LoadPhase: Sendable {
    case loading
    case loaded
    case unavailable
    case lastAttemptFailed
    case waitingForManualRefresh
}

public enum ProxyRefusalNotice: Sendable, Equatable {
    case nextAutomaticTry(Date)
    case automaticChecksPaused(until: Date)
}

@MainActor
@Observable
public final class ServerSession {
    public let profile: ServerProfile
    public let instanceID = UUID()
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let latchStore: ProfileStore?
    @ObservationIgnored private let latchGeneration: Int
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private var cachedConnection: ServerConnection?
    @ObservationIgnored private var isRetired = false
    @ObservationIgnored private let sendGate: SendGate
    @ObservationIgnored private let coordinator: ActiveRefreshCoordinator?
    @ObservationIgnored private let activeStore: (any ActiveRefreshStore)?
    @ObservationIgnored private var dataReceivedAt: Date?
    @ObservationIgnored private var automaticLimitsVisit: UUID? {
        didSet { updateAutomaticLimitsPermit() }
    }
    @ObservationIgnored let automaticLimitsPermit = SharedFlag()
    @ObservationIgnored private var publishedReadings: [String: ActiveQuota] = [:]
    private let runner = RefreshRunner()
    @ObservationIgnored public var onHeadroomUpdate: ((HeadroomSnapshot) -> Void)?
    public var refreshesAutomatically: Bool {
        didSet { updateAutomaticLimitsPermit() }
    }
    public var refreshesLimitsAutomatically: Bool {
        didSet { updateAutomaticLimitsPermit() }
    }
    public var providerRefreshInterval: TimeInterval
    public let savedSnapshot: HeadroomSnapshot?

    public private(set) var version: ServerVersion?
    public private(set) var credentials: [Credential] = []
    public private(set) var observedAt: Date?
    public private(set) var keyCounters: [ProviderKeyCounters] = []
    public private(set) var keyCountersError: APIError?
    public private(set) var routing: RoutingStrategySetting?
    public private(set) var routingLoaded = false
    public private(set) var routerSettings: RouterSettings?
    public private(set) var clientKeyCount: Int?
    public private(set) var tokenUsage: TokenUsageSummary?
    public private(set) var tokenUsageLoaded = false
    public private(set) var models: [ModelInfo] = []
    public private(set) var modelProviders: [String: Set<String>] = [:]
    public private(set) var modelFailedAccounts: [String] = []
    public private(set) var modelsLoaded = false
    public private(set) var accountModels: [String: [ModelInfo]] = [:]
    public private(set) var accountModelsFailed: Set<String> = []
    private var accountModelsLoadedAt: [String: Date] = [:]
    public private(set) var fleetLimits: FleetLimits?
    public private(set) var limitsLoaded = false
    public private(set) var accountsLoaded = false
    public private(set) var accountsLoadedAt: Date?
    public private(set) var lastRefresh: Date?
    private var lastRefreshByScope: [RefreshScope: Date] = [:]
    public private(set) var authLatch: AuthFailureLatch
    public private(set) var authError: APIError?
    public private(set) var connectionError: APIError?
    public private(set) var scopeErrors: [RefreshScope: APIError] = [:]
    public private(set) var activeQuotas: [String: ActiveQuota] = [:]
    public private(set) var providerCheckStates: [String: ActiveRefreshState] = [:]
    public private(set) var refreshingLimits: Set<String> = []
    public private(set) var limitsRefreshError: APIError?
    public private(set) var lastLimitsResults: [ActiveRefreshResult] = []
    public private(set) var providerRefreshProgress: ProviderRefreshProgress?
    public private(set) var providerRefreshReport: ProviderRefreshReport?
    public private(set) var proxyRefusalBackoff: ProxyRefusalBackoff?
    private var scopesWhoseLastLoadFailed: Set<RefreshScope> = []

    public init(
        profile: ServerProfile,
        secrets: any SecretStore,
        latchStore: ProfileStore?,
        transport: any HTTPTransport = URLSessionTransport(),
        refreshesAutomatically: Bool = true,
        coordinator: ActiveRefreshCoordinator? = nil,
        activeStore: (any ActiveRefreshStore)? = nil,
        refreshesLimitsAutomatically: Bool = false,
        providerRefreshInterval: TimeInterval = ActiveRefreshPolicy.defaultAutomaticInterval
    ) {
        self.profile = profile
        self.secrets = secrets
        self.latchStore = latchStore
        self.transport = transport
        self.refreshesAutomatically = refreshesAutomatically
        self.coordinator = coordinator
        self.activeStore = activeStore ?? latchStore
        self.refreshesLimitsAutomatically = refreshesLimitsAutomatically
        self.providerRefreshInterval = providerRefreshInterval
        savedSnapshot = latchStore?.snapshot(for: profile.id)
        let generation = latchStore?.authGeneration(for: profile.id) ?? 0
        latchGeneration = generation
        authLatch = latchStore?.authFailureLatch(for: profile.id, generation: generation) ?? AuthFailureLatch()
        sendGate = SendGate(storedPause: Self.storedPause(in: profile.isDemo ? nil : latchStore, serverID: profile.id, generation: generation))
        sendGate.setPause(authLatch.pauseReason)
        reloadProviderChecks()
        updateAutomaticLimitsPermit()
    }

    private static func storedPause(in store: ProfileStore?, serverID: UUID, generation: Int) -> @Sendable () -> AuthPauseReason? {
        guard let store else { return { nil } }
        return { store.authFailureLatch(for: serverID, generation: generation).pauseReason }
    }

    public var isRefreshing: Bool { runner.isBusy }

    public func isLoading(_ scope: RefreshScope) -> Bool { runner.isPending(scope) }

    public var pauseReason: AuthPauseReason? { authLatch.pauseReason }

    public var isAutomaticRefreshPaused: Bool { authLatch.isBlocked }

    public var headroomScope: RefreshScope {
        profile.authMode == .management ? .accounts : .limits
    }

    public func failure(for scope: RefreshScope) -> APIError? {
        authError ?? connectionError ?? scopeErrors[scope]
    }

    public func loadPhase(for scope: RefreshScope, loaded: Bool) -> LoadPhase {
        if loaded { return .loaded }
        if isLoading(scope) { return .loading }
        if failure(for: scope) != nil || isAutomaticRefreshPaused { return .unavailable }
        if scopesWhoseLastLoadFailed.contains(scope) { return .lastAttemptFailed }
        return refreshesAutomatically ? .loading : .waitingForManualRefresh
    }

    public func hasLoaded(_ scope: RefreshScope) -> Bool {
        switch (profile.authMode, scope) {
        case (.management, .accounts), (.management, .limits): accountsLoaded
        case (.management, .usage): accountsLoaded && tokenUsageLoaded
        case (_, .models): modelsLoaded
        case (.management, .settings): routingLoaded
        case (.management, .accountDetail(let name)): accountsLoaded && accountModels[name] != nil
        case (_, .accountModels(let name)): accountModels[name] != nil
        case (.clientKey, _): limitsLoaded
        }
    }

    public var accountSummaries: [AccountSummary] {
        let now = Date.now
        return switch profile.authMode {
        case .management: AccountSummary.board(credentials.map { credential in
            var summary = AccountSummary(credential: credential, active: activeQuotas[credential.stableID], now: now)
            summary.providerCheckState = providerCheckStates[credential.stableID]
            summary.accountsLoadedAt = accountsLoadedAt
            return summary
        })
        case .clientKey: AccountSummary.board((fleetLimits?.credentials ?? []).map { AccountSummary(fleet: $0, now: now) })
        }
    }

    public var headroom: [ProviderHeadroom] {
        quotaOverview(at: .now).headroom
    }

    public var pools: [ProviderPool] {
        quotaOverview(at: .now).pools
    }

    public func quotaOverview(at now: Date) -> QuotaOverview {
        if hasLoaded(headroomScope) {
            return QuotaOverview(snapshot: currentSnapshot(at: now), isSaved: false, now: now)
        }
        return savedSnapshot.map { QuotaOverview(snapshot: $0, isSaved: true, now: now) } ?? .empty
    }

    public var accountCounts: [AccountCounts] { AccountCounts.tally(credentials, now: .now) }

    public var usageSummary: UsageSummary { UsageSummary.from(credentials: credentials, keyCounters: keyCounters) }

    public func credential(id: Credential.ID) -> Credential? {
        credentials.first { $0.id == id }
    }

    public func quotaBars(for credential: Credential) -> [QuotaBar] {
        QuotaMerge.bars(passive: credential.quotaBars, active: activeQuotas[credential.stableID])
    }

    public func proxyRefusalNotice(at now: Date) -> ProxyRefusalNotice? {
        guard refreshesLimitsAutomatically, let until = proxyRefusalBackoff?.automaticChecksResume(after: now) else { return nil }
        return refreshesAutomatically ? .nextAutomaticTry(until) : .automaticChecksPaused(until: until)
    }

    public var isFleetFork: Bool {
        ServerLab.isFleetFork(version: version?.version, fleetLimitsAnswered: fleetLimits != nil)
    }

    public var supportsRouterOrder: Bool {
        profile.authMode == .management && isFleetFork
    }

    public var supportsLimitsRefresh: Bool {
        profile.authMode == .management && coordinator != nil
    }

    public func limitsTargets(_ credentialIDs: [String]? = nil, now: Date = .now) -> [ActiveTarget] {
        limitsCredentials(credentialIDs).map { ActiveTarget(credential: $0, now: now) }
    }

    private func limitsCredentials(_ credentialIDs: [String]?) -> [Credential] {
        credentials.filter { credential in credentialIDs.map { $0.contains(credential.id) } ?? true }
    }

    public func limitsRefreshPlan(for credentialIDs: [String]? = nil, now: Date = .now) -> LimitsRefreshPlan {
        LimitsRefreshPlan.make(
            targets: limitsTargets(credentialIDs, now: now),
            states: activeStore?.activeRefreshStates(proxy: refreshServer.proxy) ?? [:],
            readings: Set(sharedReadings().keys),
            now: now
        )
    }

    public func surfaceLimitsRefreshPlan(for credentialIDs: [String]? = nil, now: Date) -> LimitsRefreshPlan {
        LimitsRefreshPlan.make(targets: limitsTargets(credentialIDs, now: now), states: providerCheckStates, readings: Set(activeQuotas.keys), now: now)
    }

    private var refreshServer: ActiveRefreshServer {
        ActiveRefreshServer(serverID: profile.id, baseURL: profile.baseURL, generation: latchGeneration)
    }

    public func runAutomaticLimitsRefresh(every tick: Duration) async {
        let visit = UUID()
        automaticLimitsVisit = visit
        defer {
            if automaticLimitsVisit == visit { automaticLimitsVisit = nil }
        }
        while !Task.isCancelled {
            await refreshLimits(trigger: .automatic, origin: .visibleApp)
            do {
                try await Task.sleep(for: tick)
            } catch {
                return
            }
        }
    }

    public func refreshProviderFromSurface(_ credentialIDs: [String]? = nil) async {
        await refreshProviderFromSurface(limitsCredentials(credentialIDs), mode: .manualReadOnly)
    }

    public func providerApprovalPlan(for report: ProviderRefreshReport, now: Date) -> LimitsRefreshPlan {
        guard report.id == providerRefreshReport?.id else { return LimitsRefreshPlan() }
        return providerPlan(for: approvalCredentials(for: report), mode: approvalMode(for: report), now: now)
    }

    public func approveProviderRefresh(_ report: ProviderRefreshReport) async {
        guard !isAutomaticRefreshPaused, !providerApprovalPlan(for: report, now: .now).isEmpty else { return }
        await refreshProviderFromSurface(approvalCredentials(for: report), mode: approvalMode(for: report))
    }

    private func approvalCredentials(for report: ProviderRefreshReport) -> [Credential] {
        credentials.filter { credential in
            report.entries.contains { entry in
                entry.needsConsent && entry.id == credential.stableID && entry.account.authIndex == credential.authIndex
                    && entry.account.provider == credential.provider.lowercased()
            }
        }
    }

    private func approvalMode(for report: ProviderRefreshReport) -> ActiveRefreshMode {
        let attempts = report.entries.compactMap { entry in entry.paidKeyConsentAttemptAt.map { (entry.id, $0) } }
        return .approvedSurface(paidKeyAttempts: Dictionary(attempts, uniquingKeysWith: { _, new in new }))
    }

    private func providerPlan(for credentials: [Credential], mode: ActiveRefreshMode, now: Date) -> LimitsRefreshPlan {
        let proxy = refreshServer.proxy
        let proxyRefusedUntil: Date? = if case .approvedSurface = mode { activeStore?.proxyRefusalBackoff(proxy: proxy)?.until } else { nil }
        return LimitsRefreshPlan.make(
            targets: credentials.map { ActiveTarget(credential: $0, now: now) },
            states: activeStore?.activeRefreshStates(proxy: proxy) ?? [:],
            readings: Set(sharedReadings().keys), mode: mode, proxyRefusedUntil: proxyRefusedUntil, now: now
        )
    }

    private func refreshProviderFromSurface(_ chosen: [Credential], mode: ActiveRefreshMode) async {
        guard supportsLimitsRefresh, accountsLoaded, providerRefreshProgress == nil, refreshingLimits.isEmpty, !chosen.isEmpty else { return }
        let now = Date.now
        let targets = chosen.map { ActiveTarget(credential: $0, now: now) }
        let ready = providerPlan(for: chosen, mode: mode, now: now).readyCount
        providerRefreshReport = nil
        providerRefreshProgress = ProviderRefreshProgress(completed: 0, total: ready)
        let results = await runLimitsRefresh(chosen.map(\.id), trigger: .manual, mode: mode, surface: true)
        let byID = Dictionary(results.map { ($0.credentialID, $0) }, uniquingKeysWith: { _, new in new })
        providerRefreshReport = ProviderRefreshReport(entries: targets.map { target in
            let result = byID[target.id]
            return ProviderRefreshReport.Entry(account: target, outcome: result?.outcome ?? .notSent, paidKeyConsentAttemptAt: result?.paidKeyConsentAttemptAt)
        })
        providerRefreshProgress = nil
    }

    public func refreshLimits(_ credentialIDs: [String]? = nil, trigger: RefreshTrigger, origin: ActiveRefreshOrigin) async {
        let mode: ActiveRefreshMode = trigger == .manual ? .manual : .automatic(interval: providerRefreshInterval, origin: origin)
        _ = await runLimitsRefresh(credentialIDs, trigger: trigger, mode: mode, surface: false)
    }

    private func runLimitsRefresh(_ credentialIDs: [String]?, trigger: RefreshTrigger, mode: ActiveRefreshMode, surface: Bool) async -> [ActiveRefreshResult] {
        guard supportsLimitsRefresh, !isRetired, let coordinator else { return [] }
        switch trigger {
        case .manual:
            if case .approvedSurface = mode {
                syncLatchFromStore()
                guard !authLatch.isBlocked else { return [] }
            } else {
                _ = admit(.manual)
            }
            limitsRefreshError = nil
            if !accountsLoaded { await refresh(.accounts, trigger: .manual) }
        case .automatic:
            guard !surface, providerRefreshProgress == nil, case .automatic(_, .visibleApp) = mode, mayRefreshLimitsAutomatically(), accountsLoaded, admit(.automatic) else { return [] }
        }
        let chosen = limitsCredentials(credentialIDs)
        let targets = chosen.map { ActiveTarget(credential: $0, now: .now) }
        guard !targets.isEmpty, !isRetired else { return [] }
        guard let live = liveConnection() else {
            return targets.map { ActiveRefreshResult(credentialID: $0.id, outcome: connectionError.map(ActiveRefreshOutcome.managementFailed) ?? .notSent) }
        }
        let ids = Set(chosen.map(\.id))
        let ticket = sendGate.ticket()
        let stop = SharedFlag()
        refreshingLimits.formUnion(ids)
        let management = live.management.sending(under: ticket)
        let results = await withTaskCancellationHandler {
            await coordinator.refresh(
                targets,
                server: refreshServer,
                mode: mode,
                mayContactServer: { [weak self] in await self?.mayContactServer(for: trigger, unless: stop) ?? false },
                mayStillContactServer: { [automaticLimitsPermit] in
                    !stop.isSet && (trigger == .manual || automaticLimitsPermit.isSet)
                },
                onManagementRejection: { [weak self] rejection in await self?.recordAuthFailure(rejection) },
                onProgress: { [weak self] completed, total in
                    if surface { await self?.setProviderProgress(completed, total: total) }
                },
                send: { try await management.apiCall($0, hooks: $1) }
            )
        } onCancel: {
            stop.set(true)
        }
        refreshingLimits.subtract(ids)
        applyLimitsResults(results, authFailuresAtStart: ticket.epoch, surface: surface)
        return results
    }

    private func setProviderProgress(_ completed: Int, total: Int) {
        providerRefreshProgress = ProviderRefreshProgress(completed: completed, total: total)
    }

    private func mayRefreshLimitsAutomatically() -> Bool {
        refreshesLimitsAutomatically && refreshesAutomatically && automaticLimitsVisit != nil
    }

    private func updateAutomaticLimitsPermit() {
        automaticLimitsPermit.set(mayRefreshLimitsAutomatically())
    }

    private func mayContactServer(for trigger: RefreshTrigger, unless stop: SharedFlag) -> Bool {
        guard !isRetired, !stop.isSet else { return false }
        if trigger == .automatic, !mayRefreshLimitsAutomatically() { return false }
        syncLatchFromStore()
        return !authLatch.isBlocked
    }

    private func applyLimitsResults(_ results: [ActiveRefreshResult], authFailuresAtStart: Int, surface: Bool) {
        guard !isRetired else { return }
        lastLimitsResults = results
        readProviderChecks(publishingSurfaceResult: surface)
        let managementFailure = results.lazy.compactMap { result -> APIError? in
            if case .managementFailed(let error) = result.outcome, !error.isAuthenticationFailure { error } else { nil }
        }.first
        if let managementFailure {
            limitsRefreshError = managementFailure
        } else if results.contains(where: { if case .refreshed = $0.outcome { true } else { false } }) {
            recordAuthSuccess(ifNoFailureSince: authFailuresAtStart)
        }
        if activeQuotas != publishedReadings {
            publishProviderReadings()
        }
    }

    public func reloadProviderChecks() {
        readProviderChecks(publishingSurfaceResult: false)
    }

    private func readProviderChecks(publishingSurfaceResult: Bool) {
        guard publishingSurfaceResult || providerRefreshProgress == nil else { return }
        let readings = sharedReadings()
        if readings != activeQuotas { activeQuotas = readings }
        let states = activeStore?.activeRefreshStates(proxy: refreshServer.proxy) ?? [:]
        if states != providerCheckStates { providerCheckStates = states }
        let backoff = activeStore?.proxyRefusalBackoff(proxy: refreshServer.proxy)
        if backoff != proxyRefusalBackoff { proxyRefusalBackoff = backoff }
    }

    private func sharedReadings() -> [String: ActiveQuota] {
        activeStore?.activeQuotas(proxy: refreshServer.proxy) ?? [:]
    }

    public func retire() {
        isRetired = true
        sendGate.close()
        runner.cancel()
    }

    public func reloadFromAPI(_ scope: RefreshScope, progress: @escaping @MainActor (Double) -> Void) async -> Bool {
        let previous = lastRefresh(for: scope)
        if case .accountDetail(let name) = scope {
            let previousModels = accountModelsLoadedAt[name]
            await refreshAccountDetail(name, forceModels: true, progress: progress)
            guard accountModelsLoadedAt[name] != previousModels, !accountModelsFailed.contains(name) else { return false }
        } else if scope == .settings, profile.authMode == .management {
            await refresh(.accounts, trigger: .manual) { progress($0 * 0.65) }
            await refresh(scope, trigger: .manual) { progress(0.65 + $0 * 0.35) }
        } else {
            await refresh(scope, trigger: .manual, progress: progress)
        }
        return lastRefresh(for: scope) != previous && failure(for: scope.freshnessKey(authMode: profile.authMode)) == nil
    }

    public func refresh(_ scope: RefreshScope, trigger: RefreshTrigger, dropIfCancelled: Bool = false, progress: (@MainActor (Double) -> Void)? = nil) async {
        await runner.run(scope, trigger: trigger, dropIfCancelled: dropIfCancelled, admit: { [self] in admit($0) }) { [self] in
            await load(scope, progress: progress)
        }
    }

    public func refreshAccountDetail(_ accountName: String, forceModels: Bool = false, progress: (@MainActor (Double) -> Void)? = nil) async {
        await runner.run(.accountDetail(accountName), trigger: .manual, admit: { [self] in admit($0) }) { [self] in
            let epochAtStart = sendGate.epoch
            await load(.accounts) { progress?($0 * 0.65) }
            guard !isRetired, sendGate.epoch == epochAtStart else { return }
            guard forceModels || accountModels[accountName] == nil || refreshesAutomatically else { return }
            progress?(0.65)
            await load(.accountModels(accountName))
        }
    }

    private func load(_ scope: RefreshScope, progress: (@MainActor (Double) -> Void)? = nil) async {
        guard !isRetired else { return }
        guard let live = liveConnection() else {
            markLastLoadFailed(scope)
            return
        }
        let ticket = sendGate.ticket()
        do {
            try await ScopeLoader.load(scope, authMode: profile.authMode, management: live.management.sending(under: ticket), client: live.client.sending(under: ticket), readsRouterSettings: readsRouterSettings(for: scope), onCredentialsReceived: {
                await progress?(0.33)
            }) { [self] stage in
                await apply(stage, authFailuresAtStart: ticket.epoch)
                await progress?(0.66)
            }
            guard !isRetired else { return }
            markLoaded(scope)
            recordRefresh(of: scope, at: .now)
        } catch is CancellationError, is SendRefusal {
            return
        } catch let error as APIError where error.isPausedBeforeSending {
            guard !isRetired else { return }
            syncLatchFromStore()
            markLastLoadFailed(scope)
        } catch {
            guard !isRetired else { return }
            recordLoadFailure(APIError.wrapping(error), scope: scope)
        }
    }

    private func readsRouterSettings(for scope: RefreshScope) -> Bool {
        scope == .settings ? isFleetFork : routerSettings == nil
    }

    private func recordRefresh(of scope: RefreshScope, at date: Date) {
        guard !scope.isPerAccount else { return }
        lastRefresh = date
        for key in scope.refreshedFreshnessKeys(authMode: profile.authMode) {
            lastRefreshByScope[key] = date
        }
    }

    public func lastRefresh(for scope: RefreshScope) -> Date? {
        lastRefreshByScope[scope.freshnessKey(authMode: profile.authMode)]
    }

    private func liveConnection() -> ServerConnection? {
        do {
            let live = try connection()
            connectionError = nil
            return live
        } catch {
            connectionError = APIError.wrapping(error)
            return nil
        }
    }

    private func recordLoadFailure(_ failure: APIError, scope: RefreshScope) {
        markLastLoadFailed(scope)
        if !failure.isAuthenticationFailure, !scope.isPerAccount { scopeErrors[scope] = failure }
        recordAuthFailure(failure)
    }

    private func markLastLoadFailed(_ scope: RefreshScope) {
        if case .accountModels(let name) = scope {
            accountModelsFailed.insert(name)
        } else {
            scopesWhoseLastLoadFailed.insert(scope)
        }
    }

    private func markLoaded(_ scope: RefreshScope) {
        scopeErrors[scope] = nil
        scopesWhoseLastLoadFailed.remove(scope)
    }

    private func apply(_ data: ScopeData, authFailuresAtStart: Int) {
        guard !isRetired else { return }
        recordAuthSuccess(ifNoFailureSince: authFailuresAtStart)
        switch data {
        case .accounts(let list):
            applyAccounts(list)
        case .tokenUsage(let report):
            tokenUsage = report.map(TokenUsageSummary.from)
            tokenUsageLoaded = true
        case .catalog(let catalog):
            models = catalog.models
            modelProviders = catalog.providers
            modelFailedAccounts = catalog.failedAccounts
            modelsLoaded = true
        case .settings(let routing, let clientKeyCount):
            self.routing = routing
            routingLoaded = true
            self.clientKeyCount = clientKeyCount
        case .clientModels(let list):
            models = list
            modelsLoaded = true
        case .fleetLimits(let limits):
            fleetLimits = limits
            limitsLoaded = true
            dataReceivedAt = .now
            if let version = limits?.proxyVersion { self.version = ServerVersion(version: version) }
            publishHeadroom()
        case .accountModels(let name, let list):
            accountModels[name] = list
            accountModelsLoadedAt[name] = .now
            accountModelsFailed.remove(name)
        case .routerSettings(let settings):
            routerSettings = settings
        }
    }

    private func applyAccounts(_ list: AccountList) {
        credentials = list.credentials.value.files
        observedAt = list.credentials.value.observedAt
        version = list.credentials.version ?? version
        routerSettings = list.routerSettings ?? routerSettings
        switch list.keyCounters {
        case .success(let value):
            keyCounters = value
            keyCountersError = nil
        case .failure(let error):
            keyCountersError = error
        }
        accountsLoaded = true
        let receivedAt = Date.now
        accountsLoadedAt = receivedAt
        dataReceivedAt = receivedAt
        lastRefreshByScope[.accounts] = receivedAt
        markLoaded(.accounts)
        reloadProviderChecks()
        publishHeadroom()
    }

    public func setDisabled(_ disabled: Bool, credential: Credential) async throws {
        try await mutate { [self] management, epoch in
            try await management.setDisabled(disabled, credential: credential)
            recordAuthSuccess(ifNoFailureSince: epoch)
            try await reloadAccounts(management, epoch: epoch)
        }
    }

    public func resetCooldown(_ credential: Credential) async throws {
        guard let authIndex = credential.authIndex else { throw APIError.notFound(nil) }
        try await mutate { [self] management, epoch in
            _ = try await management.resetCooldown(authIndex: authIndex)
            recordAuthSuccess(ifNoFailureSince: epoch)
            try await reloadAccounts(management, epoch: epoch)
        }
    }

    public func setRoutingStrategy(_ strategy: String, expectedETag: String?) async throws {
        try await mutate { [self] management, epoch in
            do {
                try await management.setRoutingStrategy(strategy, ifMatch: expectedETag)
            } catch APIError.preconditionFailed {
                recordAuthSuccess(ifNoFailureSince: epoch)
                if let fresh = try await rereadRouting(management, epoch: epoch) { routing = fresh }
                throw APIError.preconditionFailed
            }
            recordAuthSuccess(ifNoFailureSince: epoch)
            routing = RoutingStrategySetting(strategy: strategy, isExplicit: true, etag: nil)
            if let fresh = try await rereadRouting(management, epoch: epoch) { routing = fresh }
        }
    }

    private func reloadAccounts(_ management: ManagementClient, epoch: Int) async throws {
        do {
            apply(.accounts(try await ScopeLoader.accounts(management)), authFailuresAtStart: epoch)
        } catch let error as APIError where error.isPausedBeforeSending {
            return
        }
    }

    private func rereadRouting(_ management: ManagementClient, epoch: Int) async throws -> RoutingStrategySetting? {
        do {
            let fresh = try await management.routingStrategy()
            recordAuthSuccess(ifNoFailureSince: epoch)
            return fresh
        } catch let error as APIError where !error.isAuthenticationFailure {
            return nil
        }
    }

    private func mutate(_ work: @escaping @MainActor (ManagementClient, Int) async throws -> Void) async throws {
        syncLatchFromStore()
        let epochAtSubmit = sendGate.epoch
        try await runner.exclusive { [self] in
            guard !isRetired else { throw CancellationError() }
            syncLatchFromStore()
            guard sendGate.epoch == epochAtSubmit else {
                throw APIError.pausedBeforeSending(sendGate.lastPauseReason)
            }
            _ = admit(.manual)
            let ticket = sendGate.ticket()
            let live = try connection()
            do {
                try await work(live.management.sending(under: ticket), ticket.epoch)
            } catch {
                recordAuthFailure(APIError.wrapping(error))
                throw error
            }
        }
    }

    private func recordAuthSuccess(ifNoFailureSince epoch: Int) {
        syncLatchFromStore()
        guard sendGate.epoch == epoch else { return }
        authError = nil
        updateLatch { $0.recordSuccess() }
    }

    private func recordAuthFailure(_ failure: APIError) {
        guard failure.isAuthenticationFailure, let reason = failure.authPauseReason, !isRetired else { return }
        authError = failure
        sendGate.recordFailure(reason)
        updateLatch { $0.record(failure) }
    }

    private func connection() throws -> ServerConnection {
        if let cachedConnection { return cachedConnection }
        let created = try ServerConnection(profile: profile, secretStore: secrets, liveTransport: transport)
        cachedConnection = created
        return created
    }

    private func admit(_ trigger: RefreshTrigger) -> Bool {
        guard !isRetired else { return false }
        syncLatchFromStore()
        var latch = authLatch
        let admitted = latch.admit(trigger, automaticRefreshEnabled: refreshesAutomatically)
        if latch != authLatch { storeLatch(latch) }
        if trigger == .manual { sendGate.setPause(nil) }
        return admitted
    }

    private func syncLatchFromStore() {
        guard !profile.isDemo, let stored = latchStore?.authFailureLatch(for: profile.id, generation: latchGeneration), stored != authLatch else { return }
        if let reason = stored.pauseReason {
            sendGate.recordFailure(reason)
        } else {
            sendGate.setPause(nil)
        }
        authLatch = stored
    }

    private func updateLatch(_ change: (inout AuthFailureLatch) -> Void) {
        var latch = authLatch
        change(&latch)
        if latch != authLatch { storeLatch(latch) }
    }

    private func storeLatch(_ latch: AuthFailureLatch) {
        guard !isRetired else { return }
        authLatch = latch
        sendGate.setPause(latch.pauseReason)
        guard !profile.isDemo else { return }
        latchStore?.saveAuthFailureLatch(latch, for: profile.id, generation: latchGeneration)
    }

    private func publishHeadroom() {
        guard !isRetired else { return }
        reloadProviderChecks()
        publishedReadings = activeQuotas
        onHeadroomUpdate?(currentSnapshot(at: .now))
    }

    private func publishProviderReadings() {
        guard !isRetired else { return }
        reloadProviderChecks()
        publishedReadings = activeQuotas
        let own = currentSnapshot(at: .now)
        onHeadroomUpdate?(newerSavedSnapshot(than: own)?.applying(active: activeQuotas) ?? own)
    }

    private func newerSavedSnapshot(than own: HeadroomSnapshot) -> HeadroomSnapshot? {
        guard let saved = latchStore?.snapshot(for: profile.id), saved.generatedAt > own.generatedAt else { return nil }
        return saved
    }

    private func currentSnapshot(at now: Date) -> HeadroomSnapshot {
        switch profile.authMode {
        case .management: .management(profile, credentials: credentials, active: activeQuotas, generatedAt: dataReceivedAt, now: now)
        case .clientKey: .clientKey(profile, limits: fleetLimits, generatedAt: dataReceivedAt, now: now)
        }
    }
}

final class SharedFlag: Sendable {
    private let value = Mutex(false)

    func set(_ isSet: Bool) {
        value.withLock { $0 = isSet }
    }

    var isSet: Bool { value.withLock { $0 } }
}

private extension RefreshScope {
    var isPerAccount: Bool {
        if case .accountModels = self { true } else { false }
    }
}
