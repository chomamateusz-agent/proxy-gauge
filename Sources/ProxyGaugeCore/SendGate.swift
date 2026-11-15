import Foundation
import Synchronization

public enum SendRefusal: Error, Equatable, Sendable {
    case closed
    case notAdmitted

    public static func happenedBeforeTransport(_ error: any Error) -> Bool {
        error is SendRefusal || (error as? APIError)?.isPausedBeforeSending == true
    }
}

public struct SendHooks: Sendable {
    public var admit: @Sendable () async -> Bool
    public var started: @Sendable () -> Void
    public var stillAdmitted: @Sendable () -> Bool
    public var withdraw: @Sendable () -> Void

    public init(
        admit: @escaping @Sendable () async -> Bool = { true },
        started: @escaping @Sendable () -> Void = {},
        stillAdmitted: @escaping @Sendable () -> Bool = { true },
        withdraw: @escaping @Sendable () -> Void = {}
    ) {
        self.admit = admit
        self.started = started
        self.stillAdmitted = stillAdmitted
        self.withdraw = withdraw
    }

    public static let none = SendHooks()

    func admitBeforeStarting() async throws {
        guard await admit() else { throw SendRefusal.notAdmitted }
    }

    func start(confirming boundary: () throws -> Void) throws {
        started()
        do {
            try boundary()
            guard stillAdmitted() else { throw SendRefusal.notAdmitted }
        } catch {
            withdraw()
            throw error
        }
    }
}

public final class SendGate: Sendable {
    public struct Ticket: Sendable {
        fileprivate let gate: SendGate
        public let epoch: Int

        func send(_ request: HTTPRequest, hooks: SendHooks, through transport: any HTTPTransport) async throws -> HTTPResponse {
            try await gate.send(request, epoch: epoch, hooks: hooks, through: transport)
        }
    }

    private struct State {
        var epoch = 0
        var pauseReason: AuthPauseReason?
        var lastPauseReason = AuthPauseReason.keyRejected
        var isClosed = false
        var isSending = false
        var queue: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    private let storedPause: @Sendable () -> AuthPauseReason?

    public init(storedPause: @escaping @Sendable () -> AuthPauseReason? = { nil }) {
        self.storedPause = storedPause
    }

    public var epoch: Int { state.withLock { $0.epoch } }

    public var lastPauseReason: AuthPauseReason { state.withLock { $0.lastPauseReason } }

    public func ticket() -> Ticket {
        Ticket(gate: self, epoch: epoch)
    }

    public func recordFailure(_ reason: AuthPauseReason) {
        state.withLock { state in
            state.epoch += 1
            state.pauseReason = reason
            state.lastPauseReason = reason
        }
    }

    public func setPause(_ reason: AuthPauseReason?) {
        state.withLock { state in
            state.pauseReason = reason
            if let reason { state.lastPauseReason = reason }
        }
    }

    public func close() {
        state.withLock { $0.isClosed = true }
    }

    private func send(_ request: HTTPRequest, epoch: Int, hooks: SendHooks, through transport: any HTTPTransport) async throws -> HTTPResponse {
        await takeTurn()
        defer { passTurn() }
        try await hooks.admitBeforeStarting()
        try hooks.start { try admit(epoch) }
        let response = try await transport.send(request)
        if !response.isSuccess, let reason = APIError.from(response).authPauseReason {
            recordFailure(reason)
        }
        return response
    }

    private func admit(_ epoch: Int) throws {
        let refusal: (any Error)? = state.withLock { state in
            if state.isClosed { return SendRefusal.closed }
            guard state.epoch == epoch, state.pauseReason == nil else {
                return APIError.pausedBeforeSending(state.pauseReason ?? state.lastPauseReason)
            }
            return nil
        }
        if let refusal { throw refusal }
        if let stored = storedPause() { throw APIError.pausedBeforeSending(stored) }
    }

    private func takeTurn() async {
        await withCheckedContinuation { (turn: CheckedContinuation<Void, Never>) in
            let startsNow = state.withLock { state in
                guard state.isSending else {
                    state.isSending = true
                    return true
                }
                state.queue.append(turn)
                return false
            }
            if startsNow { turn.resume() }
        }
    }

    private func passTurn() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.queue.isEmpty else {
                state.isSending = false
                return nil
            }
            return state.queue.removeFirst()
        }
        next?.resume()
    }
}

extension APIError {
    public var isPausedBeforeSending: Bool {
        if case .pausedBeforeSending = self { true } else { false }
    }

    public var stopsFurtherRequests: Bool {
        isAuthenticationFailure || isPausedBeforeSending
    }
}
