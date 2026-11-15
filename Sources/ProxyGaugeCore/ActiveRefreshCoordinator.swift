import Foundation
import Synchronization

public struct ActiveRefreshServer: Sendable, Equatable {
    public var serverID: UUID
    public var proxy: String
    public var generation: Int

    public init(serverID: UUID, baseURL: URL, generation: Int) {
        self.serverID = serverID
        proxy = Self.proxyKey(baseURL)
        self.generation = generation
    }

    public static func proxyKey(_ baseURL: URL) -> String {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return baseURL.absoluteString }
        let scheme = components.scheme?.lowercased()
        components.scheme = scheme
        components.host = components.host?.lowercased()
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? baseURL.absoluteString
    }
}

public protocol ActiveRefreshStore: Sendable {
    func activeRefreshStates(proxy: String) -> [String: ActiveRefreshState]
    func saveActiveRefreshState(_ state: ActiveRefreshState, credentialID: String, proxy: String)
    func restoreActiveRefreshState(_ state: ActiveRefreshState?, credentialID: String, proxy: String)
    func activeQuotas(proxy: String) -> [String: ActiveQuota]
    @discardableResult
    func saveActiveQuota(_ quota: ActiveQuota, for server: ActiveRefreshServer) -> Bool
    func proxyRefusalBackoff(proxy: String) -> ProxyRefusalBackoff?
    func saveProxyRefusalBackoff(_ backoff: ProxyRefusalBackoff?, proxy: String)
}

public final class MemoryActiveRefreshStore: ActiveRefreshStore {
    private struct Storage {
        var states: [String: [String: ActiveRefreshState]] = [:]
        var quotas: [String: [String: ActiveQuota]] = [:]
        var generations: [UUID: Int] = [:]
        var refusalBackoffs: [String: ProxyRefusalBackoff] = [:]
    }

    private let storage = Mutex(Storage())

    public init() {}

    public func activeRefreshStates(proxy: String) -> [String: ActiveRefreshState] {
        storage.withLock { $0.states[proxy] ?? [:] }
    }

    public func saveActiveRefreshState(_ state: ActiveRefreshState, credentialID: String, proxy: String) {
        storage.withLock { $0.states[proxy, default: [:]][credentialID] = state }
    }

    public func restoreActiveRefreshState(_ state: ActiveRefreshState?, credentialID: String, proxy: String) {
        storage.withLock { $0.states[proxy, default: [:]][credentialID] = state }
    }

    public func activeQuotas(proxy: String) -> [String: ActiveQuota] {
        storage.withLock { $0.quotas[proxy] ?? [:] }
    }

    @discardableResult
    public func saveActiveQuota(_ quota: ActiveQuota, for server: ActiveRefreshServer) -> Bool {
        storage.withLock { storage in
            guard storage.generations[server.serverID, default: 0] == server.generation else { return false }
            storage.quotas[server.proxy, default: [:]][quota.credentialID] = quota
            return true
        }
    }

    public func proxyRefusalBackoff(proxy: String) -> ProxyRefusalBackoff? {
        storage.withLock { $0.refusalBackoffs[proxy] }
    }

    public func saveProxyRefusalBackoff(_ backoff: ProxyRefusalBackoff?, proxy: String) {
        storage.withLock { $0.refusalBackoffs[proxy] = backoff }
    }

    public func generation(for serverID: UUID) -> Int {
        storage.withLock { $0.generations[serverID, default: 0] }
    }

    public func forgetServer(_ serverID: UUID) {
        storage.withLock { $0.generations[serverID, default: 0] += 1 }
    }

    public func forgetActiveQuotas(proxy: String) {
        storage.withLock { $0.quotas[proxy] = nil }
    }
}

public enum ActiveRefreshOutcome: Sendable, Equatable {
    case refreshed(ActiveQuota)
    case rateLimited(until: Date, partial: ActiveQuota?)
    case rejected(status: Int)
    case failed(ActiveRefreshFailure)
    case waiting(until: Date, because: ActiveRefreshWait)
    case skipped(ActiveRefreshSkip)
    case managementFailed(APIError)
    case stopped(partial: ActiveQuota?)
    case notSent
}

public struct ActiveRefreshResult: Sendable, Equatable {
    public var credentialID: String
    public var outcome: ActiveRefreshOutcome
}

public actor ActiveRefreshCoordinator {
    public typealias Sender = @Sendable (UpstreamCall, SendHooks) async throws -> UpstreamReply
    public typealias Admission = @Sendable () async -> Bool
    public typealias BoundaryCheck = @Sendable () -> Bool
    public typealias RejectionHandler = @Sendable (APIError) async -> Void

    private enum Performed: Sendable {
        case refreshed
        case rateLimited(until: Date)
        case rejected(status: Int)
        case failed(ActiveRefreshFailure)
        case stopped
        case managementFailed(APIError)
    }

    private enum Attempted: Sendable {
        case notSent
        case pausedByProxyRefusal(until: Date)
        case refusedByProxy(APIError)
        case performed(Performed)
    }

    private enum Completion: Sendable {
        case decided(ActiveRefreshOutcome)
        case pausedByProxyRefusal(until: Date)
        case refusedByProxy(APIError)
        case performed(Performed, kept: ActiveQuota?)

        var neverReachedTheProvider: Bool {
            switch self {
            case .decided(.notSent), .pausedByProxyRefusal, .refusedByProxy: true
            default: false
            }
        }
    }

    private struct Running {
        let task: Task<Completion, Never>
        var interested: [ActiveRefreshServer]
    }

    private struct Job {
        let task: Task<Completion, Never>
        let joinedAnotherCheck: Bool
    }

    private let store: any ActiveRefreshStore
    private let clock: @Sendable () -> Date
    private let jitter: @Sendable () -> Double
    private let pause: @Sendable (Duration) async -> Void
    private let providerLanes = Lanes()
    private let serverLanes = Lanes()
    private var inFlight: [String: Running] = [:]

    public init(
        store: any ActiveRefreshStore,
        clock: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...ActiveRefreshPolicy.maximumJitter) },
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.clock = clock
        self.jitter = jitter
        self.pause = pause
    }

    public func refresh(
        _ targets: [ActiveTarget],
        server: ActiveRefreshServer,
        mode: ActiveRefreshMode,
        mayContactServer: @escaping Admission = { true },
        mayStillContactServer: @escaping BoundaryCheck = { true },
        onManagementRejection: @escaping RejectionHandler = { _ in },
        send: @escaping Sender
    ) async -> [ActiveRefreshResult] {
        let batch = Batch(mayContactServer: mayContactServer, mayStillContactServer: mayStillContactServer, onRejection: onManagementRejection)
        let jobs = targets.map { target in
            (target, job(for: target, server: server, mode: mode, batch: batch, send: send))
        }
        var results: [ActiveRefreshResult] = []
        for (target, first) in jobs {
            var job = first
            var completion = await job.task.value
            while job.joinedAnotherCheck, completion.neverReachedTheProvider {
                job = self.job(for: target, server: server, mode: mode, batch: batch, send: send)
                completion = await job.task.value
            }
            results.append(ActiveRefreshResult(credentialID: target.credentialID, outcome: outcome(completion)))
        }
        return results
    }

    public func isRefreshing(_ credentialID: String, proxy: String) -> Bool {
        inFlight[Self.key(proxy, credentialID)] != nil
    }

    func participants(in credentialID: String, proxy: String) -> Int {
        inFlight[Self.key(proxy, credentialID)]?.interested.count ?? 0
    }

    private func job(for target: ActiveTarget, server: ActiveRefreshServer, mode: ActiveRefreshMode, batch: Batch, send: @escaping Sender) -> Job {
        let key = Self.key(server.proxy, target.credentialID)
        if var running = inFlight[key] {
            running.interested.append(server)
            inFlight[key] = running
            return Job(task: running.task, joinedAnotherCheck: true)
        }
        let hasReading = store.activeQuotas(proxy: server.proxy)[target.credentialID] != nil
        switch ActiveRefreshPolicy.decide(target, state: state(target.credentialID, proxy: server.proxy), mode: mode, hasReading: hasReading, now: clock()) {
        case .skip(let reason):
            return Job(task: Task { .decided(.skipped(reason)) }, joinedAnotherCheck: false)
        case .wait(let until, let reason):
            return Job(task: Task { .decided(.waiting(until: until, because: reason)) }, joinedAnotherCheck: false)
        case .run(let scope):
            if let until = automaticChecksPaused(mode, proxy: server.proxy) {
                return Job(task: Task { .decided(.waiting(until: until, because: .proxyRefused)) }, joinedAnotherCheck: false)
            }
            let task = Task {
                await self.check(target, scope: scope, server: server, mode: mode, batch: batch, send: send)
            }
            inFlight[key] = Running(task: task, interested: [server])
            return Job(task: task, joinedAnotherCheck: false)
        }
    }

    private func check(_ target: ActiveTarget, scope: ActiveScope, server: ActiveRefreshServer, mode: ActiveRefreshMode, batch: Batch, send: @escaping Sender) async -> Completion {
        let partial = PartialQuota(credentialID: target.credentialID, provider: target.provider)
        let attempted = await perform(target, scope: scope, server: server, mode: mode, batch: batch, partial: partial, send: send)
        let interested = inFlight.removeValue(forKey: Self.key(server.proxy, target.credentialID))?.interested ?? [server]
        switch attempted {
        case .notSent: return .decided(.notSent)
        case .pausedByProxyRefusal(let until): return .pausedByProxyRefusal(until: until)
        case .refusedByProxy(let error): return .refusedByProxy(error)
        case .performed(let performed): return .performed(performed, kept: keepReadings(partial, for: interested))
        }
    }

    private func outcome(_ completion: Completion) -> ActiveRefreshOutcome {
        switch completion {
        case .decided(let outcome): outcome
        case .pausedByProxyRefusal(let until): .waiting(until: until, because: .proxyRefused)
        case .refusedByProxy(let error): .managementFailed(error)
        case .performed(let performed, let kept): outcome(performed, kept: kept)
        }
    }

    private func outcome(_ performed: Performed, kept: ActiveQuota?) -> ActiveRefreshOutcome {
        switch performed {
        case .refreshed: return kept.map(ActiveRefreshOutcome.refreshed) ?? .failed(.unreadable)
        case .rateLimited(let until): return .rateLimited(until: until, partial: kept)
        case .rejected(let status): return .rejected(status: status)
        case .failed(let failure): return .failed(failure)
        case .stopped: return .stopped(partial: kept)
        case .managementFailed(let error): return .managementFailed(error)
        }
    }

    private func perform(_ target: ActiveTarget, scope: ActiveScope, server: ActiveRefreshServer, mode: ActiveRefreshMode, batch: Batch, partial: PartialQuota, send: @escaping Sender) async -> Attempted {
        let attempt = Attempt()
        let context = AdapterContext(
            target: target,
            authIndex: target.authIndex ?? "",
            scope: scope,
            send: { _, call in
                try await self.send(call, for: target, server: server, mode: mode, batch: batch, attempt: attempt, send: send)
            },
            pause: pause,
            partial: partial
        )
        do {
            try await ActiveQuotaAdapters.run(context)
            return .performed(record(target.credentialID, proxy: server.proxy) { state in
                guard partial.hasReadings else {
                    state.recordFailure(.unreadable)
                    return .failed(.unreadable)
                }
                state.recordSuccess(now: clock(), checkedProfile: partial.profileChecked)
                return .refreshed
            })
        } catch let failure as UpstreamFailure {
            return .performed(record(target.credentialID, proxy: server.proxy) { state in
                switch failure {
                case .rateLimited(let retryAfter):
                    state.recordRateLimit(provider: target.provider, retryAfter: retryAfter, now: clock())
                    return .rateLimited(until: state.rateLimitedUntil ?? clock())
                case .rejected(let status):
                    state.recordRejected(status: status)
                    return .rejected(status: status)
                case .upstream(let status):
                    state.recordFailure(.upstream(status: status))
                    return .failed(.upstream(status: status))
                case .unreadable:
                    state.recordFailure(.unreadable)
                    return .failed(.unreadable)
                }
            })
        } catch BatchStop.notSent {
            if attempt.wasSent { return .performed(.stopped) }
            return automaticChecksPaused(mode, proxy: server.proxy).map { .pausedByProxyRefusal(until: $0) } ?? .notSent
        } catch BatchStop.cancelledInTransport {
            return .performed(.stopped)
        } catch let refusal as APIError where refusal.isAuthenticationFailure && !attempt.wasSent {
            return .refusedByProxy(refusal)
        } catch {
            let wrapped = APIError.wrapping(error)
            return .performed(record(target.credentialID, proxy: server.proxy) { state in
                if let refusal = wrapped.accountRefusal {
                    state.recordFailure(.refusedByProxy(refusal))
                    return .failed(.refusedByProxy(refusal))
                }
                state.recordFailure(.management)
                return .managementFailed(wrapped)
            })
        }
    }

    private func send(_ call: UpstreamCall, for target: ActiveTarget, server: ActiveRefreshServer, mode: ActiveRefreshMode, batch: Batch, attempt: Attempt, send: Sender) async throws -> ReceivedReply {
        await providerLanes.acquire(target.provider)
        await serverLanes.acquire(server.proxy)
        do {
            guard automaticChecksPaused(mode, proxy: server.proxy) == nil else { throw BatchStop.notSent }
            try await batch.admit()
        } catch {
            await releaseLanes(target: target, server: server)
            throw error
        }
        let start = TransportStart()
        let hooks = SendHooks(
            admit: { await batch.mayStillSend() },
            started: { self.recordStart(start, of: target.credentialID, proxy: server.proxy, attempt: attempt) },
            stillAdmitted: { batch.mayStillSendNow && self.automaticChecksPaused(mode, proxy: server.proxy) == nil },
            withdraw: { self.undoStart(start, of: target.credentialID, proxy: server.proxy, attempt: attempt) }
        )
        let result: Result<UpstreamReply, any Error>
        do {
            result = .success(try await send(call, hooks))
        } catch {
            result = .failure(error)
        }
        let receivedAt = clock()
        if case .failure(let error) = result, SendRefusal.happenedBeforeTransport(error) {
            await batch.stopSending()
            await releaseLanes(target: target, server: server)
            throw BatchStop.notSent
        }
        recordStart(start, of: target.credentialID, proxy: server.proxy, attempt: attempt)
        if case .failure(let rejection as APIError) = result, rejection.isAuthenticationFailure {
            undoStart(start, of: target.credentialID, proxy: server.proxy, attempt: attempt)
        }
        recordProxyAnswer(result, proxy: server.proxy)
        await batch.report(result)
        await releaseLanes(target: target, server: server)
        let reply: UpstreamReply
        do {
            reply = try result.get()
        } catch is CancellationError {
            throw BatchStop.cancelledInTransport
        }
        if let failure = UpstreamFailure.classify(reply, now: receivedAt) { throw failure }
        return ReceivedReply(reply: reply, receivedAt: receivedAt)
    }

    private nonisolated func recordStart(_ start: TransportStart, of credentialID: String, proxy: String, attempt: Attempt) {
        guard !start.hasHappened else { return }
        let stateBefore = store.activeRefreshStates(proxy: proxy)[credentialID]
        let isFirstSend = attempt.markSent()
        start.record(isFirstSend ? .firstSend(stateBefore: stateBefore) : .laterSend)
        if isFirstSend {
            recordAttempt(credentialID, proxy: proxy)
        }
    }

    private nonisolated func undoStart(_ start: TransportStart, of credentialID: String, proxy: String, attempt: Attempt) {
        guard case .firstSend(let stateBefore)? = start.clear() else { return }
        store.restoreActiveRefreshState(stateBefore, credentialID: credentialID, proxy: proxy)
        attempt.unmark()
    }

    private func recordProxyAnswer(_ result: Result<UpstreamReply, any Error>, proxy: String) {
        switch result {
        case .success:
            if store.proxyRefusalBackoff(proxy: proxy) != nil { store.saveProxyRefusalBackoff(nil, proxy: proxy) }
        case .failure(let refusal as APIError) where refusal.refusesTheWholeProxy:
            store.saveProxyRefusalBackoff(.after(store.proxyRefusalBackoff(proxy: proxy), now: clock()), proxy: proxy)
        case .failure:
            break
        }
    }

    private nonisolated func automaticChecksPaused(_ mode: ActiveRefreshMode, proxy: String) -> Date? {
        guard mode != .manual else { return nil }
        return store.proxyRefusalBackoff(proxy: proxy)?.automaticChecksResume(after: clock())
    }

    private func releaseLanes(target: ActiveTarget, server: ActiveRefreshServer) async {
        await serverLanes.release(server.proxy)
        await providerLanes.release(target.provider)
    }

    private func keepReadings(_ partial: PartialQuota, for interested: [ActiveRefreshServer]) -> ActiveQuota? {
        guard let proxy = interested.first?.proxy else { return nil }
        let previous = store.activeQuotas(proxy: proxy)[partial.credentialID]
        guard let merged = partial.merged(onto: previous) else { return nil }
        for server in interested {
            if store.saveActiveQuota(merged, for: server) { break }
        }
        return merged
    }

    private nonisolated func recordAttempt(_ credentialID: String, proxy: String) {
        var state = state(credentialID, proxy: proxy)
        state.recordAttempt(now: clock(), jitter: jitter())
        store.saveActiveRefreshState(state, credentialID: credentialID, proxy: proxy)
    }

    private func record(_ credentialID: String, proxy: String, _ change: (inout ActiveRefreshState) -> Performed) -> Performed {
        var state = state(credentialID, proxy: proxy)
        let performed = change(&state)
        store.saveActiveRefreshState(state, credentialID: credentialID, proxy: proxy)
        return performed
    }

    private nonisolated func state(_ credentialID: String, proxy: String) -> ActiveRefreshState {
        store.activeRefreshStates(proxy: proxy)[credentialID] ?? ActiveRefreshState()
    }

    static func key(_ proxy: String, _ credentialID: String) -> String {
        proxy + "\n" + credentialID
    }
}

enum BatchStop: Error {
    case notSent
    case cancelledInTransport
}

final class Attempt: Sendable {
    private let sent = Mutex(false)

    func markSent() -> Bool {
        sent.withLock { wasSent in
            defer { wasSent = true }
            return !wasSent
        }
    }

    func unmark() {
        sent.withLock { $0 = false }
    }

    var wasSent: Bool { sent.withLock { $0 } }
}

final class TransportStart: Sendable {
    enum Recorded: Sendable {
        case firstSend(stateBefore: ActiveRefreshState?)
        case laterSend
    }

    private let state = Mutex<Recorded?>(nil)

    func record(_ recorded: Recorded) {
        state.withLock { $0 = recorded }
    }

    func clear() -> Recorded? {
        state.withLock { recorded in
            defer { recorded = nil }
            return recorded
        }
    }

    var recorded: Recorded? { state.withLock { $0 } }

    var hasHappened: Bool { recorded != nil }
}

actor Batch {
    private enum Probe {
        case unsent
        case inFlight
        case passed
    }

    private let mayContactServer: ActiveRefreshCoordinator.Admission
    private let mayStillContactServer: ActiveRefreshCoordinator.BoundaryCheck
    private let onRejection: ActiveRefreshCoordinator.RejectionHandler
    private let halted = Mutex(false)
    private var probe = Probe.unsent
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(
        mayContactServer: @escaping ActiveRefreshCoordinator.Admission,
        mayStillContactServer: @escaping ActiveRefreshCoordinator.BoundaryCheck,
        onRejection: @escaping ActiveRefreshCoordinator.RejectionHandler
    ) {
        self.mayContactServer = mayContactServer
        self.mayStillContactServer = mayStillContactServer
        self.onRejection = onRejection
    }

    private nonisolated var isHalted: Bool { halted.withLock { $0 } }

    nonisolated var mayStillSendNow: Bool { !isHalted && mayStillContactServer() }

    func admit() async throws {
        while probe == .inFlight, !isHalted {
            await withCheckedContinuation { waiting.append($0) }
        }
        guard !isHalted else { throw BatchStop.notSent }
        let isProbe = probe == .unsent
        if isProbe { probe = .inFlight }
        let allowed = await mayContactServer()
        guard allowed, !isHalted else {
            if isProbe, probe == .inFlight {
                probe = .unsent
                resumeWaiting()
            }
            throw BatchStop.notSent
        }
    }

    func mayStillSend() async -> Bool {
        guard !isHalted else { return false }
        let allowed = await mayContactServer()
        return allowed && !isHalted
    }

    func stopSending() {
        halted.withLock { $0 = true }
        resumeWaiting()
    }

    func report(_ result: Result<UpstreamReply, any Error>) async {
        switch result {
        case .failure(let rejection as APIError) where rejection.isAuthenticationFailure:
            stopSending()
            await onRejection(rejection)
        case .failure(let refusal as APIError) where refusal.refusesTheWholeProxy:
            stopSending()
        case .failure(is CancellationError):
            stopSending()
        default:
            guard probe == .inFlight else { return }
            probe = .passed
            resumeWaiting()
        }
    }

    private func resumeWaiting() {
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume() }
    }
}

actor Lanes {
    private var busy: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ lane: String) async {
        guard busy.contains(lane) else {
            busy.insert(lane)
            return
        }
        await withCheckedContinuation { waiting[lane, default: []].append($0) }
    }

    func release(_ lane: String) {
        if var queue = waiting[lane], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[lane] = queue
            next.resume()
        } else {
            busy.remove(lane)
        }
    }
}
