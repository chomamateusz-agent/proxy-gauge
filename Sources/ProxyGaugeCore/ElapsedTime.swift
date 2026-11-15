import Foundation

public enum ElapsedTime {
    private static let minuteFields: Set<Date.ComponentsFormatStyle.Field> = [.day, .hour, .minute]
    private static let secondFields: Set<Date.ComponentsFormatStyle.Field> = [.second]

    public static func text(from start: Date, to end: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let range = min(start, end)..<max(start, end)
        let fields = end.timeIntervalSince(start).magnitude < 60 ? secondFields : minuteFields
        return range.formatted(Date.ComponentsFormatStyle(style: .abbreviated, locale: locale, fields: fields))
    }
}
