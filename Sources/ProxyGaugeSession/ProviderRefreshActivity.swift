import Foundation
import ProxyGaugeCore

public struct ProviderRefreshProgress: Sendable, Equatable {
    public var completed: Int
    public let total: Int
}

public struct ProviderRefreshReport: Sendable, Identifiable {
    public struct Entry: Sendable, Identifiable {
        public let account: ActiveTarget
        public let outcome: ActiveRefreshOutcome
        let paidKeyConsentAttemptAt: Date?
        public var id: String { account.id }

        public var wasChecked: Bool { outcome.countsAsCheck }

        public var failed: Bool {
            if case .refreshed = outcome { return false }
            return wasChecked
        }

        public var needsConsent: Bool {
            if case .skipped(.requiresConsent) = outcome { return true }
            if case .failed(.requiresPaidKeyConsent) = outcome { return paidKeyConsentAttemptAt != nil }
            return false
        }
    }

    public let id = UUID()
    public let finishedAt = Date.now
    public let entries: [Entry]
    public var checked: Int { entries.filter(\.wasChecked).count }
    public var failed: Int { entries.filter(\.failed).count }
    public var needsConsent: Bool { entries.contains(where: \.needsConsent) }
}
