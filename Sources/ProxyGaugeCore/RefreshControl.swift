import Foundation
import Observation

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

    @MainActor
    private final class Turn {
        let operation: Operation
        var task: Task<Void, Never>?
        var start: CheckedContinuation<Void, Never>?
        var followers: [CheckedContinuation<Void, Never>] = []

        init(_ operation: Operation) {
            self.operation = operation
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
        turn(for: .refresh(scope)) != nil
    }

    public func run(_ scope: RefreshScope, dropIfCancelled: Bool = false, admit: () -> Bool, work: @escaping @MainActor () async -> Void) async {
        if let existing = turn(for: .refresh(scope)) {
            await withCheckedContinuation { existing.followers.append($0) }
            return
        }
        let turn = await enqueue(.refresh(scope))
        guard !(dropIfCancelled && Task.isCancelled), admit() else {
            complete(turn)
            return
        }
        await execute(turn, work)
    }

    public func exclusive<Value>(_ work: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let turn = await enqueue(.mutation)
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

    private func turn(for operation: Operation) -> Turn? {
        if let current, current.operation == operation { return current }
        return queue.first { $0.operation == operation }
    }

    private func enqueue(_ operation: Operation) async -> Turn {
        let turn = Turn(operation)
        guard current != nil else {
            current = turn
            return turn
        }
        queue.append(turn)
        await withCheckedContinuation { turn.start = $0 }
        return turn
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
