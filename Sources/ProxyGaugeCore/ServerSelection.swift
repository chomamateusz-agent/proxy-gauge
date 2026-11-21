import Foundation

public enum SelectionAfterRemoval: Equatable, Sendable {
    case keep
    case clear
    case select(UUID)

    public init(removing removed: UUID, selected: UUID?, fallback: UUID?) {
        guard selected == removed else {
            self = .keep
            return
        }
        if let fallback, fallback != removed {
            self = .select(fallback)
        } else {
            self = .clear
        }
    }
}

public enum SelectionAfterSave: Equatable, Sendable {
    case keep
    case select

    public init(saving saved: UUID, selected: UUID?, selectionExists: Bool, savedBecameDefault: Bool) {
        self = savedBecameDefault || !selectionExists || selected == saved ? .select : .keep
    }
}

public enum SectionAfterSwitch {
    public static func section<Section: Equatable>(current: Section?, available: [Section], keepsCurrent: Bool) -> Section? {
        if keepsCurrent, let current, available.contains(current) { return current }
        return available.first
    }
}
