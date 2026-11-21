import Foundation

public enum Freshness: Sendable, Equatable {
    case fresh(Date)
    case notRefreshed
    case saved(Date)
    case notReached(Date?)

    public init(failed: Bool, loaded: Bool, lastRefresh: Date?, savedAt: Date?) {
        if failed {
            self = .notReached(lastRefresh ?? savedAt)
        } else if let savedAt, !loaded {
            self = .saved(savedAt)
        } else if let lastRefresh {
            self = .fresh(lastRefresh)
        } else {
            self = .notRefreshed
        }
    }
}

public extension RefreshScope {
    func freshnessKey(authMode: AuthMode) -> RefreshScope {
        switch (authMode, self) {
        case (_, .accountModels), (.clientKey, .models): self
        case (.clientKey, _): .limits
        case (.management, .limits), (.management, .accountDetail): .accounts
        case (.management, _): self
        }
    }

    func refreshedFreshnessKeys(authMode: AuthMode) -> Set<RefreshScope> {
        switch (authMode, self) {
        case (_, .accountModels): []
        case (.management, .usage), (.management, .models): [self, .accounts]
        default: [freshnessKey(authMode: authMode)]
        }
    }
}
