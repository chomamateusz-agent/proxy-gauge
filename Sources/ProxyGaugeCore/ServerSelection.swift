import Foundation

public enum SelectionAfterRemoval: Equatable, Sendable {
    case keep
    case clear
    case select(UUID)

    public init(removing removed: UUID, selected: UUID?, usesStackNavigation: Bool, defaultServer: UUID?) {
        guard selected == removed else {
            self = .keep
            return
        }
        if !usesStackNavigation, let defaultServer, defaultServer != removed {
            self = .select(defaultServer)
        } else {
            self = .clear
        }
    }
}
