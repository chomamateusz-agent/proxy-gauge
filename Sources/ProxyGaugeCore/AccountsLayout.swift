import Foundation

public enum AccountsLayout: String, CaseIterable, Sendable, Identifiable {
    case cards
    case list
    case table
    case timeline

    public static let storageKey = "proxygauge.accounts-layout.v1"

    public var id: String { rawValue }

    public static func available(compactWidth: Bool) -> [AccountsLayout] {
        compactWidth ? [.cards, .list] : allCases
    }

    public static func resolve(_ stored: String?, compactWidth: Bool) -> AccountsLayout {
        guard let layout = stored.flatMap(AccountsLayout.init(rawValue:)), available(compactWidth: compactWidth).contains(layout) else {
            return .cards
        }
        return layout
    }
}
