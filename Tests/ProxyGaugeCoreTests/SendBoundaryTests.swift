import Foundation
import Synchronization
import Testing
@testable import ProxyGaugeCore

final class AutomaticSwitch: Sendable {
    private let on = Mutex(true)

    var isOn: Bool { on.withLock { $0 } }

    func turnOff() {
        on.withLock { $0 = false }
    }
}

enum Invalidation: CaseIterable, Sendable {
    case closeGate
    case pauseAuth
    case switchOff

    func apply(to gate: SendGate, switch automatic: AutomaticSwitch) {
        switch self {
        case .closeGate: gate.close()
        case .pauseAuth: gate.recordFailure(.keyRejected)
        case .switchOff: automatic.turnOff()
        }
    }
}

extension SendHooks {
    func invalidating(_ invalidation: Invalidation, gate: SendGate, switch automatic: AutomaticSwitch) -> SendHooks {
        var hooks = self
        let started = self.started
        hooks.started = {
            started()
            invalidation.apply(to: gate, switch: automatic)
        }
        return hooks
    }
}

@Suite("Nothing runs between the last admission check and the transport")
struct SendBoundaryTests {
    let devinCall = UpstreamCall(authIndex: "d1", url: URL(string: "https://server.codeium.com/status")!, headers: [:])

    @Test(arguments: Invalidation.allCases)
    func aRequestInvalidatedWhileItsStartIsRecordedIsNotSent(_ invalidation: Invalidation) async {
        let gate = SendGate()
        let transport = ScriptedProxy(answer: ScriptedProxy.devin)
        let automatic = AutomaticSwitch()
        let withdrawn = Mutex(false)
        let hooks = SendHooks(stillAdmitted: { automatic.isOn }, withdraw: { withdrawn.withLock { $0 = true } })
            .invalidating(invalidation, gate: gate, switch: automatic)

        let client = managementClient(transport, gate: gate)
        var refused = false
        do {
            _ = try await client.apiCall(devinCall, hooks: hooks)
        } catch {
            refused = true
        }

        #expect(refused)
        #expect(transport.sentPaths.isEmpty)
        #expect(withdrawn.withLock { $0 })
    }

    @Test(arguments: Invalidation.allCases)
    func aCheckInvalidatedWhileItsStartIsRecordedKeepsNoAttempt(_ invalidation: Invalidation) async {
        let store = MemoryActiveRefreshStore()
        let gate = SendGate()
        let transport = ScriptedProxy(answer: ScriptedProxy.devin)
        let client = managementClient(transport, gate: gate)
        let automatic = AutomaticSwitch()

        let results = await coordinator(store, clock: TestClock(activeStart)).refresh(
            [target("devin", "d1"), target("devin", "d2")],
            server: activeServer,
            mode: .manual,
            mayStillContactServer: { automatic.isOn }
        ) { call, hooks in
            try await client.apiCall(call, hooks: hooks.invalidating(invalidation, gate: gate, switch: automatic))
        }

        #expect(transport.apiCalls == 0)
        #expect(results.map(\.outcome) == [ActiveRefreshOutcome.notSent, .notSent])
        #expect(store.activeRefreshStates(proxy: activeServer.proxy).isEmpty)
    }
}

@Suite("A proxy that refuses management backs off automatic provider checks")
struct ProxyRefusalTests {
    static let remoteManagementDisabled = HTTPResponse(statusCode: 403, body: Data(#"{"error":"remote management disabled"}"#.utf8))
    static let automatic = ActiveRefreshMode.automatic(interval: 15 * 60, origin: .visibleApp)
    static let accounts = [target("devin", "d1"), target("devin", "d2"), target("devin", "d3")]

    static func outerBadRequest(_ message: String) -> HTTPResponse {
        HTTPResponse(statusCode: 400, body: Data(#"{"error":"\#(message)"}"#.utf8))
    }

    static func answering(_ authIndex: String, with refusal: HTTPResponse) -> ScriptedProxy {
        ScriptedProxy { request in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            return body.contains(#""authIndex":"\#(authIndex)""#) ? refusal : ScriptedProxy.devin(request)
        }
    }

    func waitUntilChecking(_ credentialID: String, in refresher: ActiveRefreshCoordinator) async {
        for _ in 0..<400 {
            if await refresher.isRefreshing(credentialID, proxy: activeServer.proxy) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("\(credentialID) never started checking")
    }

    func waitUntilJoined(_ credentialID: String, in refresher: ActiveRefreshCoordinator) async {
        for _ in 0..<400 {
            if await refresher.participants(in: credentialID, proxy: activeServer.proxy) > 1 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("\(credentialID) was never joined")
    }

    func refresh(_ refresher: ActiveRefreshCoordinator, _ mode: ActiveRefreshMode, _ accounts: [ActiveTarget] = Self.accounts, through transport: ScriptedProxy) async -> [ActiveRefreshResult] {
        let client = managementClient(transport)
        return await refresher.refresh(accounts, server: activeServer, mode: mode) { try await client.apiCall($0, hooks: $1) }
    }

    @Test func twoAutomaticTicksSendOneRequestInTheFirstAndNoneInTheSecond() async throws {
        let store = MemoryActiveRefreshStore()
        let clock = TestClock(activeStart)
        let refresher = coordinator(store, clock: clock)
        let refusing = ScriptedProxy { _ in Self.remoteManagementDisabled }

        let first = await refresh(refresher, Self.automatic, through: refusing)
        #expect(refusing.apiCalls == 1)
        let resume = activeStart.addingTimeInterval(ActiveRefreshPolicy.proxyRefusalBase)
        let refused = first.filter { $0.outcome == .managementFailed(.forbidden("remote management disabled")) }.map(\.credentialID)
        #expect(refused.count == 1)
        #expect(first.filter { $0.outcome == .waiting(until: resume, because: .proxyRefused) }.count == 2)
        let refusedAccount = try #require(refused.first)

        clock.advance(by: 60)
        let second = await refresh(refresher, Self.automatic, through: refusing)
        #expect(refusing.apiCalls == 1)
        let refusedAccountWait = ActiveRefreshOutcome.waiting(until: activeStart.addingTimeInterval(ActiveRefreshPolicy.manualMinimum), because: .recentlyChecked)
        for result in second {
            #expect(result.outcome == (result.credentialID == refusedAccount ? refusedAccountWait : .waiting(until: resume, because: .proxyRefused)))
        }
        #expect(store.proxyRefusalBackoff(proxy: activeServer.proxy) == ProxyRefusalBackoff(consecutiveRefusals: 1, until: resume))
    }

    @Test(arguments: [
        HTTPResponse(statusCode: 404, body: Data("404 page not found".utf8)),
        HTTPResponse(statusCode: 429, body: Data(#"{"error":"too many requests"}"#.utf8))
    ])
    func aMissingRouteOrAThrottledProxyStopsTheBatchAndBacksOff(_ refusal: HTTPResponse) async {
        let store = MemoryActiveRefreshStore()
        let refusing = ScriptedProxy { _ in refusal }

        _ = await refresh(coordinator(store, clock: TestClock(activeStart)), Self.automatic, through: refusing)

        #expect(refusing.apiCalls == 1)
        #expect(store.proxyRefusalBackoff(proxy: activeServer.proxy)?.consecutiveRefusals == 1)
    }

    @Test(arguments: [
        ("auth token refresh failed", ProxyAccountRefusal.signInRefreshFailed),
        ("auth credential not found for auth_index", .accountNotFound),
        ("auth token not found", .signInMissing),
        ("invalid url", .requestRejected)
    ])
    func aBadRequestForOneAccountFailsOnlyThatAccount(_ message: String, _ expected: ProxyAccountRefusal) async {
        for mode in [ActiveRefreshMode.manual, Self.automatic] {
            let store = MemoryActiveRefreshStore()
            let proxy = Self.answering("d2", with: Self.outerBadRequest(message))

            let results = await refresh(coordinator(store, clock: TestClock(activeStart)), mode, through: proxy)

            #expect(proxy.apiCalls == 3)
            for result in results {
                if result.credentialID == "d2" {
                    #expect(result.outcome == .failed(.refusedByProxy(expected)))
                } else {
                    #expect(result.outcome.quota != nil)
                }
            }
            #expect(store.activeRefreshStates(proxy: activeServer.proxy)["d2"]?.lastFailure == .refusedByProxy(expected))
            #expect(store.proxyRefusalBackoff(proxy: activeServer.proxy) == nil)
        }
    }

    @Test func aProxyRefusalAfterAProviderRejectionIsExplainedAlongsideIt() async {
        let store = MemoryActiveRefreshStore()
        let clock = TestClock(activeStart)
        let refresher = coordinator(store, clock: clock)
        let providerRejection = ScriptedProxy { _ in .json(#"{"status_code":401,"header":{},"body":"{}"}"#) }
        let rejected = await refresh(refresher, .manual, [target("devin", "d1")], through: providerRejection)
        #expect(rejected.map(\.outcome) == [.rejected(status: 401)])

        clock.advance(by: 2 * 3_600)
        let refusal = ScriptedProxy { _ in Self.outerBadRequest("auth token refresh failed") }
        _ = await refresh(refresher, .manual, [target("devin", "d1")], through: refusal)

        let state = store.activeRefreshStates(proxy: activeServer.proxy)["d1"]
        #expect(state?.rejectedStatus == 401)
        #expect(state?.lastFailureNote == .refusedByProxy(.signInRefreshFailed))
        let automatic = await refresh(refresher, Self.automatic, [target("devin", "d1")], through: refusal)
        #expect(automatic.map(\.outcome) == [.skipped(.rejectedByProvider)])
        #expect(refusal.apiCalls == 1)
    }

    @Test(arguments: [
        (ActiveRefreshFailure.refusedByProxy(.accountNotFound), ProviderCheckFailureNote?.some(.refusedByProxy(.accountNotFound))),
        (.upstream(status: 502), .upstream(status: 502)),
        (.unreadable, .unreadable),
        (.rejected(status: 403), nil),
        (.rateLimited, nil),
        (.management, nil)
    ])
    func theLastFailureNoteLeavesOutWhatOtherNotesAlreadySay(_ failure: ActiveRefreshFailure, _ expected: ProviderCheckFailureNote?) {
        var state = ActiveRefreshState()
        state.recordRejected(status: 401)
        state.recordFailure(failure)
        #expect(state.rejectedStatus == 401)
        #expect(state.lastFailureNote == expected)
    }

    @Test func anAutomaticCheckQueuedBehindARefusedBatchDoesNotSend() async {
        let store = MemoryActiveRefreshStore()
        let refresher = coordinator(store, clock: TestClock(activeStart))
        let held = Latch()
        let refusing = ScriptedProxy(holdingFirstRequestUntil: held) { _ in Self.remoteManagementDisabled }

        let manual = Task { await refresh(refresher, .manual, [target("devin", "d1")], through: refusing) }
        await waitUntil { refusing.apiCalls == 1 }
        let automatic = Task { await refresh(refresher, Self.automatic, [target("devin", "d2")], through: refusing) }
        await waitUntilChecking("d2", in: refresher)
        held.open()

        _ = await manual.value
        let queued = await automatic.value
        let resume = activeStart.addingTimeInterval(ActiveRefreshPolicy.proxyRefusalBase)
        #expect(refusing.apiCalls == 1)
        #expect(queued.map(\.outcome) == [.waiting(until: resume, because: .proxyRefused)])
        #expect(store.activeRefreshStates(proxy: activeServer.proxy)["d2"] == nil)
    }

    @Test func aManualCheckQueuedBehindARefusedBatchStillSends() async {
        let store = MemoryActiveRefreshStore()
        let refresher = coordinator(store, clock: TestClock(activeStart))
        let held = Latch()
        let refusing = ScriptedProxy(holdingFirstRequestUntil: held) { _ in Self.remoteManagementDisabled }

        let first = Task { await refresh(refresher, .manual, [target("devin", "d1")], through: refusing) }
        await waitUntil { refusing.apiCalls == 1 }
        let second = Task { await refresh(refresher, .manual, [target("devin", "d2")], through: refusing) }
        await waitUntilChecking("d2", in: refresher)
        held.open()

        _ = await first.value
        _ = await second.value
        #expect(refusing.apiCalls == 2)
        #expect(store.proxyRefusalBackoff(proxy: activeServer.proxy)?.consecutiveRefusals == 2)
    }

    @Test func aManualRefreshThatJoinedAnAutomaticCheckStoppedByTheRefusalStillSends() async throws {
        let store = MemoryActiveRefreshStore()
        let refresher = coordinator(store, clock: TestClock(activeStart))
        let held = Latch()
        let answered = Mutex(0)
        let proxy = ScriptedProxy(holdingFirstRequestUntil: held) { request in
            let isFirstAnswer = answered.withLock { count in
                count += 1
                return count == 1
            }
            return isFirstAnswer ? Self.remoteManagementDisabled : ScriptedProxy.devin(request)
        }

        let automatic = Task { await refresh(refresher, Self.automatic, [target("devin", "d1"), target("devin", "d2")], through: proxy) }
        await waitUntil { proxy.apiCalls == 1 }
        let sentFirst = try #require(proxy.sentBodies.first)
        let queued = sentFirst.contains(#""authIndex":"d1""#) ? "d2" : "d1"
        await waitUntilChecking(queued, in: refresher)
        let manual = Task { await refresh(refresher, .manual, [target("devin", queued)], through: proxy) }
        await waitUntilJoined(queued, in: refresher)
        held.open()

        let automaticResults = await automatic.value
        let manualResults = await manual.value
        let resume = activeStart.addingTimeInterval(ActiveRefreshPolicy.proxyRefusalBase)
        #expect(automaticResults.first { $0.credentialID == queued }?.outcome == .waiting(until: resume, because: .proxyRefused))
        #expect(manualResults.map(\.credentialID) == [queued])
        #expect(manualResults.first?.outcome.quota != nil)
        #expect(proxy.apiCalls == 2)
    }

    @Test func aBackoffRecordedWhileAnAutomaticCheckStartsStopsItAtTheSendBoundary() async {
        let store = MemoryActiveRefreshStore()
        let refresher = coordinator(store, clock: TestClock(activeStart))
        let transport = ScriptedProxy(answer: ScriptedProxy.devin)
        let client = managementClient(transport)
        let backoff = ProxyRefusalBackoff.after(nil, now: activeStart)

        let results = await refresher.refresh([target("devin", "d1")], server: activeServer, mode: Self.automatic) { call, hooks in
            var recording = hooks
            recording.started = {
                hooks.started()
                store.saveProxyRefusalBackoff(backoff, proxy: activeServer.proxy)
            }
            return try await client.apiCall(call, hooks: recording)
        }

        #expect(transport.apiCalls == 0)
        #expect(results.map(\.outcome) == [.waiting(until: backoff.until, because: .proxyRefused)])
        #expect(store.activeRefreshStates(proxy: activeServer.proxy).isEmpty)
    }

    @Test func aManualRefreshTriesAgainAndASuccessfulAnswerEndsTheBackoff() async {
        let store = MemoryActiveRefreshStore()
        let clock = TestClock(activeStart)
        let refresher = coordinator(store, clock: clock)
        let refusing = ScriptedProxy { _ in Self.remoteManagementDisabled }
        _ = await refresh(refresher, Self.automatic, through: refusing)

        clock.advance(by: 60)
        _ = await refresh(refresher, .manual, through: refusing)
        #expect(refusing.apiCalls == 2)
        #expect(store.proxyRefusalBackoff(proxy: activeServer.proxy)?.consecutiveRefusals == 2)

        let fixed = ScriptedProxy(answer: ScriptedProxy.devin)
        let outcomes = await refresh(refresher, .manual, through: fixed).map(\.outcome)
        #expect(outcomes.contains { $0.quota != nil })
        #expect(store.proxyRefusalBackoff(proxy: activeServer.proxy) == nil)
    }

    @Test func theBackoffDoublesFromFifteenMinutesUpToSixHours() {
        var backoff: ProxyRefusalBackoff?
        var waits: [TimeInterval] = []
        for _ in 0..<7 {
            let next = ProxyRefusalBackoff.after(backoff, now: activeStart)
            waits.append(next.until.timeIntervalSince(activeStart))
            backoff = next
        }
        #expect(waits == [900, 1_800, 3_600, 7_200, 14_400, 21_600, 21_600])
    }

    @Test func aRejectedKeyStillLeavesNoWaitAndNoProxyBackoff() async {
        let store = MemoryActiveRefreshStore()
        let refresher = coordinator(store, clock: TestClock(activeStart))
        let rejecting = ScriptedProxy { _ in ScriptedManagement.managementRejection }

        _ = await refresh(refresher, Self.automatic, through: rejecting)

        #expect(rejecting.apiCalls == 1)
        #expect(store.activeRefreshStates(proxy: activeServer.proxy).isEmpty)
        #expect(store.proxyRefusalBackoff(proxy: activeServer.proxy) == nil)
    }
}
