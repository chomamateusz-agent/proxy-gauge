import Foundation

public enum TimelineScale: String, CaseIterable, Sendable, Identifiable {
    case weekly
    case fiveHour

    public static let storageKey = "proxygauge.timeline-scale.v1"

    public var id: String { rawValue }

    public func includes(_ window: QuotaWindow) -> Bool {
        switch self {
        case .weekly: window.isWeekly
        case .fiveHour: window == .session5h
        }
    }

    public func range(around now: Date, calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .weekly:
            let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -2, to: now)!)
            let end = calendar.date(byAdding: .day, value: 14, to: start)!
            return DateInterval(start: start, end: end)
        case .fiveHour:
            let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            return DateInterval(start: hour.addingTimeInterval(-6 * 3_600), duration: 24 * 3_600)
        }
    }

    public func ticks(in range: DateInterval, calendar: Calendar = .current) -> [Date] {
        let component: Calendar.Component = self == .weekly ? .day : .hour
        let step = self == .weekly ? 1 : 3
        var ticks: [Date] = []
        var tick = range.start
        while tick < range.end {
            ticks.append(tick)
            guard let next = calendar.date(byAdding: component, value: step, to: tick) else { break }
            tick = next
        }
        return ticks
    }
}

public struct TimelineLane: Sendable, Equatable, Identifiable {
    public var barID: String
    public var label: String?
    public var remainingPercent: Double?
    public var current: DateInterval?
    public var next: DateInterval?
    public var startsOnUse: Bool
    public var resetPassed: Bool

    public var id: String { barID }
    public var window: QuotaWindow { QuotaWindow(barID: barID) }

    public static func lanes(bars: [QuotaBar], provider: String, scale: TimelineScale, now: Date) -> [TimelineLane] {
        bars.sortedForDisplay().filter { scale.includes($0.window) }.map { bar in
            let duration = bar.window.duration
            let resetsAt = bar.resetsAt.flatMap { $0 > now ? $0 : nil }
            return TimelineLane(
                barID: bar.id,
                label: bar.label,
                remainingPercent: bar.remainingPercent(at: now),
                current: both(resetsAt, duration).map { DateInterval(start: $0.addingTimeInterval(-$1), end: $0) },
                next: both(resetsAt, duration).map { DateInterval(start: $0, duration: $1) },
                startsOnUse: bar.startsOnUse(provider: provider, at: now),
                resetPassed: bar.hasReset(at: now)
            )
        }
    }

    public func nextWindow(after block: PoolAccount.Block?) -> DateInterval? {
        guard let next else { return nil }
        guard let block else { return next }
        guard let until = block.until else { return nil }
        return until > next.start ? DateInterval(start: until, duration: next.duration) : next
    }

    public func windowStartingAfter(_ block: PoolAccount.Block?, now: Date) -> DateInterval? {
        guard current == nil, startsOnUse || resetPassed, let duration = window.duration else { return nil }
        guard let block else { return DateInterval(start: now, duration: duration) }
        return block.until.map { DateInterval(start: max(now, $0), duration: duration) }
    }
}

private func both<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
    guard let first, let second else { return nil }
    return (first, second)
}
