import Foundation
import Observation
import Synchronization

public enum RefreshTrigger: Sendable, Equatable {
    case automatic
    case manual
}

public enum AuthPauseReason: String, Sendable, Codable {
    case keyRejected
    case ipBanned
}

extension APIError {
    public var authPauseReason: AuthPauseReason? {
        if case .ipBanned = self { return .ipBanned }
        return isAuthenticationFailure ? .keyRejected : nil
    }
}

public struct AuthFailureLatch: Sendable, Equatable {
    public private(set) var pauseReason: AuthPauseReason?

    public init(pauseReason: AuthPauseReason? = nil) {
        self.pauseReason = pauseReason
    }

    public var isBlocked: Bool { pauseReason != nil }

    public mutating func admit(_ trigger: RefreshTrigger) -> Bool {
        switch trigger {
        case .manual:
            pauseReason = nil
            return true
        case .automatic:
            return !isBlocked
        }
    }

    public mutating func recordSuccess() {
        pauseReason = nil
    }

    public mutating func record(_ error: APIError) {
        if let reason = error.authPauseReason {
            pauseReason = reason
        }
    }
}

public enum RefreshScope: Hashable, Sendable {
    case accounts
    case usage
    case models
    case settings
    case limits
    case accountModels(String)
}

@MainActor
@Observable
public final class RefreshRunner {
    private enum Operation: Equatable {
        case refresh(RefreshScope)
        case mutation
    }

    private final class Waiter: Sendable {
        let trigger: RefreshTrigger
        let mayBeDropped: Bool
        private let cancelled = Mutex(false)

        init(trigger: RefreshTrigger, mayBeDropped: Bool) {
            self.trigger = trigger
            self.mayBeDropped = mayBeDropped
        }

        func markCancelled() {
            cancelled.withLock { $0 = true }
        }

        var stillWantsTheRefresh: Bool {
            !(mayBeDropped && cancelled.withLock { $0 })
        }
    }

    @MainActor
    private final class Turn {
        let operation: Operation
        var task: Task<Void, Never>?
        var start: CheckedContinuation<Void, Never>?
        var waiters: [Waiter] = []
        var followers: [CheckedContinuation<Void, Never>] = []

        init(_ operation: Operation) {
            self.operation = operation
        }

        var wantedTrigger: RefreshTrigger? {
            let wanted = waiters.filter(\.stillWantsTheRefresh)
            guard !wanted.isEmpty else { return nil }
            return wanted.contains { $0.trigger == .manual } ? .manual : .automatic
        }
    }

    @MainActor
    private final class Outcome<Value> {
        var result: Result<Value, any Error>?
    }

    private var current: Turn?
    private var queue: [Turn] = []

    public init() {}

    public var inFlight: RefreshScope? {
        if case .refresh(let scope) = current?.operation { return scope }
        return nil
    }

    public var isBusy: Bool { current != nil }

    public func isPending(_ scope: RefreshScope) -> Bool {
        current?.operation == .refresh(scope) || queue.contains { $0.operation == .refresh(scope) }
    }

    public func run(
        _ scope: RefreshScope,
        trigger: RefreshTrigger,
        dropIfCancelled: Bool = false,
        admit: @escaping @MainActor (RefreshTrigger) -> Bool,
        work: @escaping @MainActor () async -> Void
    ) async {
        let waiter = Waiter(trigger: trigger, mayBeDropped: dropIfCancelled)
        await withTaskCancellationHandler {
            if let existing = joinableTurn(for: scope) {
                await follow(existing, as: waiter)
            } else {
                await runOwnTurn(scope, waiter: waiter, admit: admit, work: work)
            }
        } onCancel: {
            waiter.markCancelled()
        }
    }

    public func exclusive<Value>(_ work: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let turn = Turn(.mutation)
        await enqueue(turn)
        let outcome = Outcome<Value>()
        await execute(turn) {
            do {
                outcome.result = .success(try await work())
            } catch {
                outcome.result = .failure(error)
            }
        }
        guard let result = outcome.result else { throw CancellationError() }
        return try result.get()
    }

    public func cancel() {
        current?.task?.cancel()
    }

    private func follow(_ turn: Turn, as waiter: Waiter) async {
        turn.waiters.append(waiter)
        await withCheckedContinuation { turn.followers.append($0) }
    }

    private func runOwnTurn(
        _ scope: RefreshScope,
        waiter: Waiter,
        admit: @escaping @MainActor (RefreshTrigger) -> Bool,
        work: @escaping @MainActor () async -> Void
    ) async {
        let turn = Turn(.refresh(scope))
        turn.waiters = [waiter]
        await enqueue(turn)
        guard let trigger = turn.wantedTrigger, admit(trigger) else {
            complete(turn)
            return
        }
        await execute(turn) {
            await work()
            if Self.manualRetryIsWanted(after: trigger, by: turn, admit: admit) {
                await work()
            }
        }
    }

    private static func manualRetryIsWanted(after trigger: RefreshTrigger, by turn: Turn, admit: (RefreshTrigger) -> Bool) -> Bool {
        trigger == .automatic
            && turn.wantedTrigger == .manual
            && !Task.isCancelled
            && !admit(.automatic)
            && admit(.manual)
    }

    private func joinableTurn(for scope: RefreshScope) -> Turn? {
        let operation = Operation.refresh(scope)
        if let lastMutation = queue.lastIndex(where: { $0.operation == .mutation }) {
            return queue[(lastMutation + 1)...].first { $0.operation == operation }
        }
        if let current, current.operation == operation { return current }
        return queue.first { $0.operation == operation }
    }

    private func enqueue(_ turn: Turn) async {
        guard current != nil else {
            current = turn
            return
        }
        queue.append(turn)
        await withCheckedContinuation { turn.start = $0 }
    }

    private func execute(_ turn: Turn, _ work: @escaping @MainActor () async -> Void) async {
        let task = Task { @MainActor in
            await work()
            self.complete(turn)
        }
        turn.task = task
        await task.value
    }

    private func complete(_ turn: Turn) {
        let followers = turn.followers
        turn.followers = []
        followers.forEach { $0.resume() }
        guard current === turn else { return }
        guard !queue.isEmpty else {
            current = nil
            return
        }
        let next = queue.removeFirst()
        current = next
        next.start?.resume()
    }
}
