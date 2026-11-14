import Foundation
import Observation

public enum RefreshTrigger: Sendable, Equatable {
    case automatic
    case manual
}

public struct AuthFailureLatch: Sendable, Equatable {
    public private(set) var isBlocked: Bool

    public init(isBlocked: Bool = false) {
        self.isBlocked = isBlocked
    }

    public mutating func admit(_ trigger: RefreshTrigger) -> Bool {
        switch trigger {
        case .manual:
            isBlocked = false
            return true
        case .automatic:
            return !isBlocked
        }
    }

    public mutating func recordSuccess() {
        isBlocked = false
    }

    public mutating func record(_ error: APIError) {
        if error.isAuthenticationFailure {
            isBlocked = true
        }
    }
}

public struct ResponseSequencer: Sendable, Equatable {
    private var issued = 0
    private var applied = 0
    private var oldestAcceptable = 0

    public init() {}

    public mutating func issue() -> Int {
        issued += 1
        return issued
    }

    public mutating func discardOutstanding() {
        oldestAcceptable = issued + 1
    }

    public mutating func accept(_ ticket: Int) -> Bool {
        guard ticket >= oldestAcceptable, ticket > applied else { return false }
        applied = ticket
        return true
    }
}

public enum RefreshScope: Hashable, Sendable {
    case accounts
    case usage
    case models
    case settings
    case limits
    case accountModels(String)

    var includesAccountList: Bool {
        switch self {
        case .accounts, .usage, .models, .limits: true
        case .settings, .accountModels: false
        }
    }
}

public enum RefreshStep: Sendable, Equatable {
    case start
    case joinInFlight
    case waitForInFlight
}

public enum RefreshPlanner {
    public static func step(for requested: RefreshScope, inFlight: RefreshScope?) -> RefreshStep {
        guard let inFlight else { return .start }
        return inFlight == requested ? .joinInFlight : .waitForInFlight
    }
}

@MainActor
@Observable
public final class RefreshRunner {
    private struct Running {
        let scope: RefreshScope
        let id: Int
        let task: Task<Void, Never>
    }

    private var running: Running?
    @ObservationIgnored private var issued = 0

    public init() {}

    public var inFlight: RefreshScope? { running?.scope }

    public func run(_ scope: RefreshScope, admit: () -> Bool, work: @escaping @MainActor () async -> Void) async {
        while let current = running {
            let step = RefreshPlanner.step(for: scope, inFlight: current.scope)
            await current.task.value
            if step == .joinInFlight { return }
        }
        guard admit() else { return }
        issued += 1
        let id = issued
        let task = Task { @MainActor in
            await work()
            self.finish(id)
        }
        running = Running(scope: scope, id: id, task: task)
        await task.value
    }

    public func cancel() {
        running?.task.cancel()
    }

    private func finish(_ id: Int) {
        if running?.id == id { running = nil }
    }
}
