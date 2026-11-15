import Foundation
import Synchronization
import Testing
@testable import ProxyGaugeCore

final class Latch: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var hasWaiters: Bool { state.withLock { !$0.waiters.isEmpty } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = state.withLock { state in
                if !state.isOpen { state.waiters.append(continuation) }
                return state.isOpen
            }
            if passes { continuation.resume() }
        }
    }

    func open() {
        let released = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        released.forEach { $0.resume() }
    }
}

final class ScriptedProxy: HTTPTransport, Sendable {
    typealias Answer = @Sendable (HTTPRequest) throws -> HTTPResponse

    private let paths = Mutex<[String]>([])
    private let bodies = Mutex<[String]>([])
    private let firstRequestHeld: Latch?
    private let answer: Answer

    init(holdingFirstRequestUntil latch: Latch? = nil, answer: @escaping Answer) {
        firstRequestHeld = latch
        self.answer = answer
    }

    var sentPaths: [String] { paths.withLock { $0 } }

    var apiCalls: Int { sentPaths.filter { $0.hasSuffix("/requests/api-call") }.count }

    var sentBodies: [String] { bodies.withLock { $0 } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        bodies.withLock { $0.append(String(decoding: request.body ?? Data(), as: UTF8.self)) }
        let isFirst = paths.withLock { paths in
            paths.append(request.url.path())
            return paths.count == 1
        }
        if isFirst, let firstRequestHeld { await firstRequestHeld.wait() }
        return try answer(request)
    }

    static func devin(_ request: HTTPRequest) -> HTTPResponse {
        request.url.path().hasSuffix("/requests/api-call") ? ScriptedManagement.devinStatus : .json("{}")
    }
}

func managementClient(_ transport: any HTTPTransport, gate: SendGate? = nil) -> ManagementClient {
    let client = ManagementClient(baseURL: testBaseURL, managementKey: "test-key", transport: transport)
    return gate.map { client.sending(under: $0.ticket()) } ?? client
}

func refreshDevin(_ refresher: ActiveRefreshCoordinator, server: ActiveRefreshServer = activeServer, through client: ManagementClient) async -> ActiveRefreshOutcome? {
    await refresher.refresh([target("devin", "d1")], server: server, mode: .manual) { try await client.apiCall($0, hooks: $1) }.first?.outcome
}

@Suite("Provider checks count from the moment the transport starts")
struct TransportStartTests {
    let devinCall = UpstreamCall(authIndex: "d1", url: URL(string: "https://server.codeium.com/status")!, headers: [:])

    @Test func aRequestQueuedAtTheGateIsRefusedWhenItsAdmissionEndsWhileItWaits() async throws {
        let held = Latch()
        let transport = ScriptedProxy(holdingFirstRequestUntil: held) { _ in .json("{}") }
        let gated = managementClient(transport, gate: SendGate())
        let allowed = Mutex(true)
        let started = Mutex(false)
        let hooks = SendHooks(admit: { allowed.withLock { $0 } }, started: { started.withLock { $0 = true } })

        let read = Task { try await gated.upstreamKeyCounters() }
        await waitUntil { transport.sentPaths.count == 1 }
        let check = Task { [devinCall] in try await gated.apiCall(devinCall, hooks: hooks) }
        try await Task.sleep(for: .milliseconds(30))
        allowed.withLock { $0 = false }
        held.open()

        _ = try await read.value
        await #expect(throws: SendRefusal.notAdmitted) { try await check.value }
        #expect(transport.apiCalls == 0)
        #expect(!started.withLock { $0 })
    }

    @Test func theWaitCountsFromTheActualSendNotFromWhenTheCheckQueued() async throws {
        let clock = TestClock(activeStart)
        let store = MemoryActiveRefreshStore()
        let held = Latch()
        let transport = ScriptedProxy(holdingFirstRequestUntil: held) { request in
            request.url.path().hasSuffix("/requests/api-call") ? ScriptedManagement.upstream(500, "{}") : .json("{}")
        }
        let gated = managementClient(transport, gate: SendGate())

        let read = Task { try await gated.upstreamKeyCounters() }
        await waitUntil { transport.sentPaths.count == 1 }
        let check = Task { await refreshDevin(coordinator(store, clock: clock), through: gated) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.activeRefreshStates(proxy: activeServer.proxy)["d1"] == nil)
        clock.advance(by: 120)
        held.open()
        _ = try await read.value

        #expect(await check.value == .failed(.upstream(status: 500)))
        let state = try #require(store.activeRefreshStates(proxy: activeServer.proxy)["d1"])
        #expect(state.lastAttemptAt == activeStart.addingTimeInterval(120))
        #expect(state.nextAllowedAt == activeStart.addingTimeInterval(120 + ActiveRefreshPolicy.manualMinimum))
    }

    @Test func aTransportCancelledAfterItStartedKeepsTheAttemptAndItsWait() async {
        let store = MemoryActiveRefreshStore()
        let refresher = coordinator(store, clock: TestClock(activeStart))
        let transport = ScriptedProxy { _ in throw URLError(.cancelled) }

        #expect(await refreshDevin(refresher, through: managementClient(transport)) == .stopped(partial: nil))
        #expect(store.activeRefreshStates(proxy: activeServer.proxy)["d1"]?.lastAttemptAt == activeStart)

        let again = await refreshDevin(refresher, through: managementClient(transport))
        #expect(again == .waiting(until: activeStart.addingTimeInterval(ActiveRefreshPolicy.manualMinimum), because: .recentlyChecked))
        #expect(transport.apiCalls == 1)
    }

    @Test func aClosedGateRefusesBeforeTheTransportAndLeavesNoAttempt() async {
        let store = MemoryActiveRefreshStore()
        let gate = SendGate()
        gate.close()
        let transport = ScriptedProxy(answer: ScriptedProxy.devin)

        #expect(await refreshDevin(coordinator(store, clock: TestClock(activeStart)), through: managementClient(transport, gate: gate)) == .notSent)
        #expect(store.activeRefreshStates(proxy: activeServer.proxy)["d1"] == nil)
        #expect(transport.sentPaths.isEmpty)
    }

    @Test func aRejectedManagementKeyLeavesNoWaitBecauseTheProviderWasNotContacted() async {
        let store = MemoryActiveRefreshStore()
        let refresher = coordinator(store, clock: TestClock(activeStart))
        let rejecting = ScriptedProxy { _ in ScriptedManagement.managementRejection }

        #expect(await refreshDevin(refresher, through: managementClient(rejecting)) == .managementFailed(.unauthorized("invalid management key")))
        #expect(store.activeRefreshStates(proxy: activeServer.proxy)["d1"] == nil)

        let fixed = ScriptedProxy(answer: ScriptedProxy.devin)
        #expect(await refreshDevin(refresher, through: managementClient(fixed))?.quota != nil)
        #expect(fixed.apiCalls == 1)
    }

    @Test func anEntryThatJoinedACheckTheProxyRefusedRunsItWithItsOwnKey() async {
        let store = MemoryActiveRefreshStore()
        let refresher = coordinator(store, clock: TestClock(activeStart))
        let held = Latch()
        let stale = ScriptedProxy(holdingFirstRequestUntil: held) { _ in ScriptedManagement.managementRejection }
        let valid = ScriptedProxy(answer: ScriptedProxy.devin)
        let staleEntry = ActiveRefreshServer(serverID: UUID(), baseURL: testBaseURL, generation: 0)
        let validEntry = ActiveRefreshServer(serverID: UUID(), baseURL: testBaseURL, generation: 0)

        let first = Task { await refreshDevin(refresher, server: staleEntry, through: managementClient(stale)) }
        await waitUntil { stale.apiCalls == 1 }
        let joined = Task { await refreshDevin(refresher, server: validEntry, through: managementClient(valid)) }
        try? await Task.sleep(for: .milliseconds(30))
        held.open()

        #expect(await first.value == .managementFailed(.unauthorized("invalid management key")))
        #expect(await joined.value?.quota != nil)
        #expect(valid.apiCalls == 1)
        #expect(store.activeQuotas(proxy: validEntry.proxy)["d1"] != nil)
    }

    @Test func aFinishedAccountIsSavedWhileAnEarlierAccountIsStillRunning() async {
        let store = MemoryActiveRefreshStore()
        let grantsDelay = Latch()
        let refresher = ActiveRefreshCoordinator(store: store, clock: { activeStart }, jitter: { 0 }, pause: { _ in await grantsDelay.wait() })
        let stub = UpstreamStub(delay: .milliseconds(1))

        let batch = Task { await run(refresher, [target("claude", "c1"), target("devin", "d1")], through: stub) }
        await waitUntil { grantsDelay.hasWaiters && store.activeQuotas(proxy: activeServer.proxy)["d1"] != nil }
        let savedWhileFirstPaused = store.activeQuotas(proxy: activeServer.proxy)["d1"] != nil
        let firstStillPaused = grantsDelay.hasWaiters
        let firstNotSavedYet = store.activeQuotas(proxy: activeServer.proxy)["c1"] == nil
        grantsDelay.open()
        let results = await batch.value

        #expect(savedWhileFirstPaused)
        #expect(firstStillPaused)
        #expect(firstNotSavedYet)
        #expect(results.allSatisfy { $0.outcome.quota != nil })
    }
}
