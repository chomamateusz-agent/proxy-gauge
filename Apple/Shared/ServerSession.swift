import Foundation
import Observation
import ProxyGaugeCore
import ProxyGaugeStore

enum LoadPhase {
    case loading
    case loaded
    case unavailable
}

@MainActor
@Observable
final class ServerSession {
    let profile: ServerProfile
    let instanceID = UUID()
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let latchStore: ProfileStore?
    @ObservationIgnored private let latchGeneration: Int
    @ObservationIgnored private var cachedConnection: ServerConnection?
    @ObservationIgnored private var accountsSequencer = ResponseSequencer()
    @ObservationIgnored private var isRetired = false
    private let runner = RefreshRunner()
    var onHeadroomUpdate: ((HeadroomSnapshot) -> Void)?

    private(set) var version: ServerVersion?
    private(set) var credentials: [Credential] = []
    private(set) var observedAt: Date?
    private(set) var keyCounters: [ProviderKeyCounters] = []
    private(set) var keyCountersError: APIError?
    private(set) var routing: RoutingStrategySetting?
    private(set) var routingLoaded = false
    private(set) var clientKeyCount: Int?
    private(set) var tokenUsage: TokenUsageSummary?
    private(set) var tokenUsageLoaded = false
    private(set) var models: [ModelInfo] = []
    private(set) var modelProviders: [String: Set<String>] = [:]
    private(set) var modelFailedAccounts: [String] = []
    private(set) var modelsLoaded = false
    private(set) var accountModels: [String: [ModelInfo]] = [:]
    private(set) var accountModelsFailed: Set<String> = []
    private(set) var fleetLimits: FleetLimits?
    private(set) var limitsLoaded = false
    private(set) var accountsLoaded = false
    private(set) var lastRefresh: Date?
    private(set) var authLatch: AuthFailureLatch
    var lastError: APIError?

    init(profile: ServerProfile, secrets: any SecretStore, latchStore: ProfileStore?) {
        self.profile = profile
        self.secrets = secrets
        self.latchStore = latchStore
        latchGeneration = latchStore?.authGeneration(for: profile.id) ?? 0
        authLatch = latchStore?.authFailureLatch(for: profile.id) ?? AuthFailureLatch()
    }

    var isRefreshing: Bool { runner.inFlight != nil }

    var isAutomaticRefreshPaused: Bool { authLatch.isBlocked }

    func loadPhase(loaded: Bool) -> LoadPhase {
        if loaded { return .loaded }
        if isRefreshing || (lastError == nil && !isAutomaticRefreshPaused) { return .loading }
        return .unavailable
    }

    var headroom: [ProviderHeadroom] {
        switch profile.authMode {
        case .management: HeadroomCalculator.fromCredentials(credentials, now: .now)
        case .clientKey: fleetLimits.map(HeadroomCalculator.fromFleet) ?? []
        }
    }

    var accountCounts: [AccountCounts] { AccountCounts.tally(credentials, now: .now) }

    var usageSummary: UsageSummary { UsageSummary.from(credentials: credentials, keyCounters: keyCounters) }

    func credential(id: Credential.ID) -> Credential? {
        credentials.first { $0.id == id }
    }

    func retire() {
        isRetired = true
        runner.cancel()
    }

    func refresh(_ scope: RefreshScope, trigger: RefreshTrigger) async {
        await runner.run(scope, admit: { admit(trigger) }) { [self] in
            await perform(scope)
        }
    }

    private func perform(_ scope: RefreshScope) async {
        guard !isRetired else { return }
        let live: ServerConnection
        do {
            live = try connection()
        } catch {
            lastError = APIError.wrapping(error)
            return
        }
        let ticket = accountsSequencer.issue()
        do {
            let data = try await ScopeLoader.load(scope, authMode: profile.authMode, management: live.management, client: live.client)
            guard !isRetired else { return }
            apply(data, ticket: ticket)
            if case .accountModels = scope {} else {
                lastRefresh = .now
                lastError = nil
            }
            updateLatch { $0.recordSuccess() }
        } catch is CancellationError {
            return
        } catch {
            guard !isRetired else { return }
            if case .accountModels(let name) = scope { accountModelsFailed.insert(name) }
            recordFailure(error)
        }
    }

    private func apply(_ data: ScopeData, ticket: Int) {
        switch data {
        case .accounts(let list):
            applyAccounts(list, ticket: ticket)
        case .usage(let list, let report):
            applyAccounts(list, ticket: ticket)
            tokenUsage = report.map(TokenUsageSummary.from)
            tokenUsageLoaded = true
        case .models(let list, let catalog):
            applyAccounts(list, ticket: ticket)
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

    private func applyAccounts(_ list: AccountList, ticket: Int) {
        guard accountsSequencer.accept(ticket) else { return }
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
        publishHeadroom()
    }

    func setDisabled(_ disabled: Bool, credential: Credential) async throws {
        let live = try connection()
        try await recordingFailures {
            try await live.management.setDisabled(disabled, credential: credential)
            try await reloadAfterMutation(live)
        }
    }

    func resetCooldown(_ credential: Credential) async throws {
        guard let authIndex = credential.authIndex else { throw APIError.notFound(nil) }
        let live = try connection()
        try await recordingFailures {
            _ = try await live.management.resetCooldown(authIndex: authIndex)
            try await reloadAfterMutation(live)
        }
    }

    private func reloadAfterMutation(_ live: ServerConnection) async throws {
        accountsSequencer.discardOutstanding()
        let ticket = accountsSequencer.issue()
        let list = try await ScopeLoader.accounts(live.management)
        guard !isRetired else { return }
        applyAccounts(list, ticket: ticket)
    }

    func setRoutingStrategy(_ strategy: String, expectedETag: String?) async throws {
        let live = try connection()
        do {
            try await live.management.setRoutingStrategy(strategy, ifMatch: expectedETag)
        } catch APIError.preconditionFailed {
            if let fresh = try? await live.management.routingStrategy() { routing = fresh }
            throw APIError.preconditionFailed
        } catch {
            recordFailure(error)
            throw error
        }
        if let fresh = try? await live.management.routingStrategy() {
            routing = fresh
        } else {
            routing = RoutingStrategySetting(strategy: strategy, isExplicit: true, etag: nil)
        }
    }

    private func recordingFailures(_ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch {
            if !(error is CancellationError) { recordFailure(error) }
            throw error
        }
    }

    private func recordFailure(_ error: any Error) {
        let failure = APIError.wrapping(error)
        lastError = failure
        updateLatch { $0.record(failure) }
    }

    private func connection() throws -> ServerConnection {
        if let cachedConnection { return cachedConnection }
        let created = try ServerConnection(profile: profile, secretStore: secrets)
        cachedConnection = created
        return created
    }

    private func admit(_ trigger: RefreshTrigger) -> Bool {
        guard !isRetired else { return false }
        if let stored = latchStore?.authFailureLatch(for: profile.id), stored != authLatch { authLatch = stored }
        var latch = authLatch
        let admitted = latch.admit(trigger)
        if latch != authLatch { storeLatch(latch) }
        return admitted
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
