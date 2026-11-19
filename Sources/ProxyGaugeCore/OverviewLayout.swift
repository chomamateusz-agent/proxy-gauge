import Foundation

public enum OverviewLayout: String, CaseIterable, Sendable, Identifiable {
    case answerFirst
    case compactRows
    case accountsStrip

    public static let storageKey = "proxygauge.overview-layout.v1"
    public static let standard = OverviewLayout.compactRows

    public var id: String { rawValue }

    public static func resolve(_ stored: String?) -> OverviewLayout {
        stored.flatMap(OverviewLayout.init(rawValue:)) ?? standard
    }
}
