import Foundation
import Observation
import ProxyGaugeCore
import ProxyGaugeStore

public enum LoadPhase: Sendable {
    case loading
    case loaded
    case unavailable
    case lastAttemptFailed
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
    @ObservationIgnored private var authFailuresSeen = 0
    @ObservationIgnored private var lastAuthPauseReason: AuthPauseReason = .keyRejected
    private let runner = RefreshRunner()
    @ObservationIgnored public var onHeadroomUpdate: ((HeadroomSnapshot) -> Void)?

    public private(set) var version: ServerVersion?
    public private(set) var credentials: [Credential] = []
    public private(set) var observedAt: Date?
    public private(set) var keyCounters: [ProviderKeyCounters] = []
    public private(set) var keyCountersError: APIError?
    public private(set) var routing: RoutingStrategySetting?
    public private(set) var routingLoaded = false
    public private(set) var clientKeyCount: Int?
    public private(set) var tokenUsage: TokenUsageSummary?
    public private(set) var tokenUsageLoaded = false
    public private(set) var models: [ModelInfo] = []
    public private(set) var modelProviders: [String: Set<String>] = [:]
    public private(set) var modelFailedAccounts: [String] = []
    public private(set) var modelsLoaded = false
    public private(set) var accountModels: [String: [ModelInfo]] = [:]
    public private(set) var accountModelsFailed: Set<String> = []
    public private(set) var fleetLimits: FleetLimits?
    public private(set) var limitsLoaded = false
    public private(set) var accountsLoaded = false
    public private(set) var lastRefresh: Date?
    public private(set) var authLatch: AuthFailureLatch
    public private(set) var authError: APIError?
    public private(set) var connectionError: APIError?
    public private(set) var scopeErrors: [RefreshScope: APIError] = [:]
    private var scopesWhoseLastLoadFailed: Set<RefreshScope> = []

    public init(profile: ServerProfile, secrets: any SecretStore, latchStore: ProfileStore?, transport: any HTTPTransport = URLSessionTransport()) {
        self.profile = profile
        self.secrets = secrets
        self.latchStore = latchStore
        self.transport = transport
        let generation = latchStore?.authGeneration(for: profile.id) ?? 0
        latchGeneration = generation
        authLatch = latchStore?.authFailureLatch(for: profile.id, generation: generation) ?? AuthFailureLatch()
    }

    public var isRefreshing: Bool { runner.isBusy }

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
        if runner.isPending(scope) { return .loading }
        if failure(for: scope) != nil || isAutomaticRefreshPaused { return .unavailable }
        if scopesWhoseLastLoadFailed.contains(scope) { return .lastAttemptFailed }
        return .loading
    }

    public var headroom: [ProviderHeadroom] {
        switch profile.authMode {
        case .management: HeadroomCalculator.fromCredentials(credentials, now: .now)
        case .clientKey: fleetLimits.map(HeadroomCalculator.fromFleet) ?? []
        }
    }

    public var accountCounts: [AccountCounts] { AccountCounts.tally(credentials, now: .now) }

    public var usageSummary: UsageSummary { UsageSummary.from(credentials: credentials, keyCounters: keyCounters) }

    public func credential(id: Credential.ID) -> Credential? {
        credentials.first { $0.id == id }
    }

    public func retire() {
        isRetired = true
        runner.cancel()
    }

    public func refresh(_ scope: RefreshScope, trigger: RefreshTrigger, dropIfCancelled: Bool = false) async {
        await runner.run(scope, trigger: trigger, dropIfCancelled: dropIfCancelled, admit: { [self] in admit($0) }) { [self] in
            await load(scope)
        }
    }

    private func load(_ scope: RefreshScope) async {
        guard !isRetired else { return }
        guard let live = liveConnection() else {
            markLastLoadFailed(scope)
            return
        }
        do {
            try await ScopeLoader.load(scope, authMode: profile.authMode, management: live.management, client: live.client) { [self] stage in
                await apply(stage)
            }
            guard !isRetired else { return }
            markLoaded(scope)
            if !scope.isPerAccount { lastRefresh = .now }
        } catch is CancellationError {
            return
        } catch {
            guard !isRetired else { return }
            recordLoadFailure(APIError.wrapping(error), scope: scope)
        }
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

    private func apply(_ data: ScopeData) {
        guard !isRetired else { return }
        recordAuthSuccess()
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
            if let version = limits?.proxyVersion { self.version = ServerVersion(version: version) }
            publishHeadroom()
        case .accountModels(let name, let list):
            accountModels[name] = list
            accountModelsFailed.remove(name)
        }
    }

    private func applyAccounts(_ list: AccountList) {
        credentials = list.credentials.value.files
        observedAt = list.credentials.value.observedAt
        version = list.credentials.version ?? version
        switch list.keyCounters {
        case .success(let value):
            keyCounters = value
            keyCountersError = nil
        case .failure(let error):
            keyCountersError = error
        }
        accountsLoaded = true
        markLoaded(.accounts)
        publishHeadroom()
    }

    public func setDisabled(_ disabled: Bool, credential: Credential) async throws {
        try await mutate { [self] live in
            try await live.management.setDisabled(disabled, credential: credential)
            recordAuthSuccess()
            try await reloadAccounts(live)
        }
    }

    public func resetCooldown(_ credential: Credential) async throws {
        guard let authIndex = credential.authIndex else { throw APIError.notFound(nil) }
        try await mutate { [self] live in
            _ = try await live.management.resetCooldown(authIndex: authIndex)
            recordAuthSuccess()
            try await reloadAccounts(live)
        }
    }

    public func setRoutingStrategy(_ strategy: String, expectedETag: String?) async throws {
        try await mutate { [self] live in
            do {
                try await live.management.setRoutingStrategy(strategy, ifMatch: expectedETag)
            } catch APIError.preconditionFailed {
                recordAuthSuccess()
                if let fresh = try await rereadRouting(live) { routing = fresh }
                throw APIError.preconditionFailed
            }
            recordAuthSuccess()
            routing = RoutingStrategySetting(strategy: strategy, isExplicit: true, etag: nil)
            if let fresh = try await rereadRouting(live) { routing = fresh }
        }
    }

    private func reloadAccounts(_ live: ServerConnection) async throws {
        let list = try await ScopeLoader.accounts(live.management)
        apply(.accounts(list))
    }

    private func rereadRouting(_ live: ServerConnection) async throws -> RoutingStrategySetting? {
        do {
            let fresh = try await live.management.routingStrategy()
            recordAuthSuccess()
            return fresh
        } catch let error as APIError where !error.isAuthenticationFailure {
            return nil
        }
    }

    private func mutate(_ work: @escaping @MainActor (ServerConnection) async throws -> Void) async throws {
        syncLatchFromStore()
        let authFailuresAtSubmit = authFailuresSeen
        try await runner.exclusive { [self] in
            guard !isRetired else { throw CancellationError() }
            syncLatchFromStore()
            if authFailuresSeen != authFailuresAtSubmit {
                throw APIError.pausedBeforeSending(lastAuthPauseReason)
            }
            let live = try connection()
            do {
                try await work(live)
            } catch {
                recordAuthFailure(APIError.wrapping(error))
                throw error
            }
        }
    }

    private func recordAuthSuccess() {
        authError = nil
        updateLatch { $0.recordSuccess() }
    }

    private func recordAuthFailure(_ failure: APIError) {
        guard failure.isAuthenticationFailure, !isRetired else { return }
        authError = failure
        authFailuresSeen += 1
        if let reason = failure.authPauseReason { lastAuthPauseReason = reason }
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
        let admitted = latch.admit(trigger)
        if latch != authLatch { storeLatch(latch) }
        return admitted
    }

    private func syncLatchFromStore() {
        guard !profile.isDemo, let stored = latchStore?.authFailureLatch(for: profile.id, generation: latchGeneration), stored != authLatch else { return }
        if let reason = stored.pauseReason {
            authFailuresSeen += 1
            lastAuthPauseReason = reason
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
        guard !profile.isDemo else { return }
        latchStore?.saveAuthFailureLatch(latch, for: profile.id, generation: latchGeneration)
    }

    private func publishHeadroom() {
        guard !isRetired else { return }
        let source: HeadroomSnapshot.Source = switch profile.authMode {
        case .management: .passiveObservations
        case .clientKey: fleetLimits == nil ? .unavailable : .fleetLimits
        }
        onHeadroomUpdate?(HeadroomSnapshot(
            serverID: profile.id,
            serverName: profile.name,
            isDemo: profile.isDemo,
            generatedAt: .now,
            source: source,
            providers: headroom
        ))
    }
}

private extension RefreshScope {
    var isPerAccount: Bool {
        if case .accountModels = self { true } else { false }
    }
}
