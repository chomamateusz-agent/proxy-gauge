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
        var latch = AuthFailureLatch(isBlocked: true)
        let manualAdmitted = latch.admit(.manual)
        #expect(manualAdmitted)
        #expect(!latch.isBlocked)
        latch.record(.unauthorized(nil))
        let automaticAdmitted = latch.admit(.automatic)
        #expect(!automaticAdmitted)
    }

    @Test func successClearsTheBlock() {
        var latch = AuthFailureLatch(isBlocked: true)
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

@Suite("Response sequencer")
struct ResponseSequencerTests {
    @Test func olderResponseCannotOverwriteANewerOne() {
        var sequencer = ResponseSequencer()
        let slowRefresh = sequencer.issue()
        let mutationReload = sequencer.issue()
        let newerAccepted = sequencer.accept(mutationReload)
        let olderAccepted = sequencer.accept(slowRefresh)
        #expect(newerAccepted)
        #expect(!olderAccepted)
    }

    @Test func inOrderResponsesAreAccepted() {
        var sequencer = ResponseSequencer()
        let first = sequencer.issue()
        let firstAccepted = sequencer.accept(first)
        let second = sequencer.issue()
        let secondAccepted = sequencer.accept(second)
        #expect(firstAccepted)
        #expect(secondAccepted)
    }

    @Test func discardingOutstandingRejectsResponsesIssuedBefore() {
        var sequencer = ResponseSequencer()
        let inFlight = sequencer.issue()
        sequencer.discardOutstanding()
        let staleAccepted = sequencer.accept(inFlight)
        let next = sequencer.issue()
        let nextAccepted = sequencer.accept(next)
        #expect(!staleAccepted)
        #expect(nextAccepted)
    }
}

@Suite("Refresh planner")
struct RefreshPlannerTests {
    @Test func idleServerStartsAtOnce() {
        #expect(RefreshPlanner.step(for: .models, inFlight: nil) == .start)
    }

    @Test func sameScopeJoinsTheRunningRefresh() {
        #expect(RefreshPlanner.step(for: .accounts, inFlight: .accounts) == .joinInFlight)
    }

    @Test func otherScopeWaitsInsteadOfBeingDropped() {
        #expect(RefreshPlanner.step(for: .models, inFlight: .accounts) == .waitForInFlight)
        #expect(RefreshPlanner.step(for: .accountModels("a.json"), inFlight: .accountModels("b.json")) == .waitForInFlight)
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

    @Test func pausedRefreshDoesNotStart() async {
        let runner = RefreshRunner()
        var runs = 0
        await runner.run(.accounts, admit: { false }) { runs += 1 }
        #expect(runs == 0)
        #expect(runner.inFlight == nil)
    }
}
