import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Auth failure latch")
struct AuthFailureLatchTests {
    @Test(arguments: [
        APIError.unauthorized("invalid management key"),
        APIError.unauthorized(nil),
        APIError.ipBanned(retryAt: nil),
        APIError.forbidden(nil)
    ])
    func authFailuresStopAutomaticRefresh(error: APIError) {
        var latch = AuthFailureLatch()
        let firstAdmitted = latch.admit(.automatic)
        latch.record(error)
        let laterAdmitted = latch.admit(.automatic)
        #expect(firstAdmitted)
        #expect(!laterAdmitted)
        #expect(latch.isBlocked)
    }

    @Test(arguments: [
        APIError.forbidden("remote management disabled"),
        APIError.transport("offline"),
        APIError.server(status: 503, message: nil),
        APIError.notFound(nil),
        APIError.decoding("x")
    ])
    func otherFailuresKeepAutomaticRefresh(error: APIError) {
        var latch = AuthFailureLatch()
        latch.record(error)
        let admitted = latch.admit(.automatic)
        #expect(admitted)
    }

    @Test func manualRefreshRetriesOnceAndReblocksOnAnotherFailure() {
        var latch = AuthFailureLatch(pauseReason: .keyRejected)
        let manualAdmitted = latch.admit(.manual)
        #expect(manualAdmitted)
        #expect(!latch.isBlocked)
        latch.record(.unauthorized(nil))
        let automaticAdmitted = latch.admit(.automatic)
        #expect(!automaticAdmitted)
    }

    @Test func pauseRemembersWhetherTheKeyOrTheAddressWasBlocked() {
        var latch = AuthFailureLatch()
        latch.record(.ipBanned(retryAt: nil))
        #expect(latch.pauseReason == .ipBanned)
        latch.record(.unauthorized(nil))
        #expect(latch.pauseReason == .keyRejected)
        latch.record(.transport("offline"))
        #expect(latch.pauseReason == .keyRejected)
    }

    @Test func successClearsTheBlock() {
        var latch = AuthFailureLatch(pauseReason: .keyRejected)
        latch.recordSuccess()
        let admitted = latch.admit(.automatic)
        #expect(admitted)
    }

    @Test func automaticLoopsStayUnderTheServerBan() {
        let serverBanThreshold = 5
        var latch = AuthFailureLatch()
        var failedAttempts = 0
        let loopsPerMinute = ["menu bar", "detail view", "widget", "detail view", "menu bar", "widget", "detail view"]
        for _ in 0..<100 {
            for _ in loopsPerMinute where latch.admit(.automatic) {
                failedAttempts += 1
                latch.record(.unauthorized("invalid management key"))
            }
        }
        #expect(failedAttempts == 1)
        #expect(failedAttempts < serverBanThreshold)
    }
}

@MainActor
final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
@Suite("Refresh runner")
struct RefreshRunnerTests {
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func automaticRefreshWaitsForTheRunningOneAndThenRuns() async {
        let runner = RefreshRunner()
        let gate = Gate()
        var log: [String] = []
        let first = Task { await runner.run(.accounts, admit: { true }) { log.append("accounts start"); await gate.wait(); log.append("accounts end") } }
        await settle()
        let second = Task { await runner.run(.models, admit: { log.append("models admitted"); return true }) { log.append("models") } }
        await settle()
        #expect(log == ["accounts start"])
        #expect(runner.inFlight == .accounts)
        gate.open()
        await first.value
        await second.value
        #expect(log == ["accounts start", "accounts end", "models admitted", "models"])
        #expect(runner.inFlight == nil)
    }

    @Test func waitingRefreshRechecksTheLatchAfterARejection() async {
        let runner = RefreshRunner()
        let gate = Gate()
        var latch = AuthFailureLatch()
        var requests = 0
        let first = Task {
            await runner.run(.accounts, admit: { latch.admit(.automatic) }) {
                requests += 1
                await gate.wait()
                latch.record(.unauthorized("invalid management key"))
            }
        }
        await settle()
        let second = Task { await runner.run(.models, admit: { latch.admit(.automatic) }) { requests += 1 } }
        await settle()
        gate.open()
        await first.value
        await second.value
        #expect(requests == 1)
        #expect(latch.isBlocked)
    }

    @Test func sameScopeRunsOnce() async {
        let runner = RefreshRunner()
        let gate = Gate()
        var runs = 0
        let first = Task { await runner.run(.accounts, admit: { true }) { runs += 1; await gate.wait() } }
        await settle()
        let second = Task { await runner.run(.accounts, admit: { true }) { runs += 1 } }
        await settle()
        gate.open()
        await first.value
        await second.value
        #expect(runs == 1)
    }

    @Test func cancellingTheCallerDoesNotCancelTheLoad() async {
        let runner = RefreshRunner()
        let gate = Gate()
        var finished = false
        let caller = Task { await runner.run(.models, admit: { true }) { await gate.wait(); finished = !Task.isCancelled } }
        await settle()
        caller.cancel()
        gate.open()
        await caller.value
        #expect(finished)
    }

    @Test func cancelledWaiterThatMayBeDroppedNeverStarts() async {
        let runner = RefreshRunner()
        let gate = Gate()
        var log: [String] = []
        let first = Task { await runner.run(.accounts, admit: { true }) { await gate.wait(); log.append("accounts") } }
        await settle()
        let obsolete = Task { await runner.run(.models, dropIfCancelled: true, admit: { log.append("models admitted"); return true }) { log.append("models") } }
        await settle()
        #expect(runner.isPending(.models))
        obsolete.cancel()
        gate.open()
        await first.value
        await obsolete.value
        #expect(log == ["accounts"])
        #expect(!runner.isPending(.models))
    }

    @Test func cancelledWaiterThatMustNotBeDroppedStillRuns() async {
        let runner = RefreshRunner()
        let gate = Gate()
        var log: [String] = []
        let first = Task { await runner.run(.accounts, admit: { true }) { await gate.wait(); log.append("accounts") } }
        await settle()
        let detail = Task { await runner.run(.accountModels("a.json"), admit: { true }) { log.append("account models") } }
        await settle()
        detail.cancel()
        gate.open()
        await first.value
        await detail.value
        #expect(log == ["accounts", "account models"])
    }

    @Test func refreshesAndMutationsRunOneAtATimeInArrivalOrder() async throws {
        let runner = RefreshRunner()
        let refreshGate = Gate()
        let mutationGate = Gate()
        var log: [String] = []
        let refresh = Task { await runner.run(.accounts, admit: { true }) { log.append("refresh start"); await refreshGate.wait(); log.append("refresh end") } }
        await settle()
        let mutation = Task { try await runner.exclusive { log.append("mutation start"); await mutationGate.wait(); log.append("mutation end"); return 7 } }
        await settle()
        let later = Task { await runner.run(.usage, admit: { true }) { log.append("later refresh") } }
        await settle()
        #expect(log == ["refresh start"])
        #expect(runner.isPending(.usage))
        refreshGate.open()
        await refresh.value
        await settle()
        #expect(log == ["refresh start", "refresh end", "mutation start"])
        #expect(runner.isBusy)
        #expect(runner.inFlight == nil)
        mutationGate.open()
        #expect(try await mutation.value == 7)
        await later.value
        #expect(log == ["refresh start", "refresh end", "mutation start", "mutation end", "later refresh"])
        #expect(!runner.isBusy)
    }

    @Test func queuedRefreshOfTheSameScopeIsJoinedNotRepeated() async {
        let runner = RefreshRunner()
        let gate = Gate()
        var runs: [RefreshScope] = []
        let first = Task { await runner.run(.models, admit: { true }) { runs.append(.models); await gate.wait() } }
        await settle()
        let menuBar = Task { await runner.run(.accounts, admit: { true }) { runs.append(.accounts) } }
        let root = Task { await runner.run(.accounts, admit: { true }) { runs.append(.accounts) } }
        await settle()
        gate.open()
        await first.value
        await menuBar.value
        await root.value
        #expect(runs == [.models, .accounts])
    }

    @Test func mutationErrorsReachTheCaller() async {
        let runner = RefreshRunner()
        await #expect(throws: APIError.preconditionFailed) {
            try await runner.exclusive { () async throws -> Void in throw APIError.preconditionFailed }
        }
        #expect(!runner.isBusy)
    }

    @Test func pausedRefreshDoesNotStart() async {
        let runner = RefreshRunner()
        var runs = 0
        await runner.run(.accounts, admit: { false }) { runs += 1 }
        #expect(runs == 0)
        #expect(runner.inFlight == nil)
    }
}
