import ProxyGaugeCore
import SwiftUI

enum TimelineStyle {
    static let labelWidth: CGFloat = 230
    static let nameHeight: CGFloat = 20
    static let laneHeight: CGFloat = 22
    static let rowPadding: CGFloat = 8
    static let axisHeight: CGFloat = 30
}

extension TimelineScale {
    var title: LocalizedStringResource {
        switch self {
        case .weekly: "Weekly"
        case .fiveHour: "5-hour"
        }
    }
}

struct AccountsTimeline: View {
    let accounts: [AccountSummary]
    @AppStorage(TimelineScale.storageKey) private var storedScale = TimelineScale.weekly.rawValue

    private var scale: TimelineScale { TimelineScale(rawValue: storedScale) ?? .weekly }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let range = scale.range(around: now)
            VStack(alignment: .leading, spacing: 10) {
                header(range: range)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Account")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: TimelineStyle.labelWidth, alignment: .leading)
                        TimelineAxis(scale: scale, range: range, now: now)
                    }
                    .frame(height: TimelineStyle.axisHeight)
                    ForEach(accounts) { account in
                        Divider()
                        TimelineAccountRow(account: account, scale: scale, range: range, now: now)
                    }
                }
                TimelineLegend()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BoardStyle.cardBackground, in: .rect(cornerRadius: BoardStyle.cornerRadius))
    }

    private func header(range: DateInterval) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quota windows")
                    .font(.headline)
                Group {
                    if scale == .weekly {
                        Text(range.start ..< range.end.addingTimeInterval(-1), format: .interval.month(.abbreviated).day())
                    } else {
                        Text(range.start ..< range.end, format: .interval.month(.abbreviated).day().hour().minute())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Window", selection: $storedScale) {
                ForEach(TimelineScale.allCases) { scale in
                    Text(scale.title).tag(scale.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

private struct TimelineAxis: View {
    let scale: TimelineScale
    let range: DateInterval
    let now: Date

    var body: some View {
        GeometryReader { proxy in
            let ticks = scale.ticks(in: range)
            let mapper = TimelineMapper(range: range, width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.self) { tick in
                    let next = scale == .weekly ? Calendar.current.date(byAdding: .day, value: 1, to: tick)! : tick.addingTimeInterval(3 * 3_600)
                    let isCurrent = (tick..<next).contains(now)
                    VStack(spacing: 0) {
                        if scale == .weekly {
                            Text(tick, format: .dateTime.weekday(.abbreviated))
                            Text(tick, format: .dateTime.month(.defaultDigits).day())
                                .fontWeight(.semibold)
                        } else {
                            Text(tick, format: .dateTime.hour().minute())
                                .fontWeight(.semibold)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .frame(width: mapper.x(next) - mapper.x(tick), height: TimelineStyle.axisHeight)
                    .background(isCurrent ? Color.accentColor.opacity(0.12) : .clear)
                    .offset(x: mapper.x(tick))
                }
            }
        }
    }
}

struct TimelineMapper {
    let range: DateInterval
    let width: CGFloat

    func x(_ date: Date) -> CGFloat {
        let fraction = date.timeIntervalSince(range.start) / range.duration
        return width * CGFloat(min(1, max(0, fraction)))
    }

    func span(_ interval: DateInterval) -> (x: CGFloat, width: CGFloat)? {
        guard interval.end > range.start, interval.start < range.end else { return nil }
        let start = x(interval.start)
        return (start, max(2, x(interval.end) - start))
    }
}

private struct TimelineAccountRow: View {
    let account: AccountSummary
    let scale: TimelineScale
    let range: DateInterval
    let now: Date

    var body: some View {
        let lanes = TimelineLane.lanes(bars: account.bars, provider: account.provider, scale: scale, now: now)
        let height = TimelineStyle.nameHeight + CGFloat(max(1, lanes.count)) * TimelineStyle.laneHeight + TimelineStyle.rowPadding
        HStack(alignment: .top, spacing: 0) {
            labels(lanes)
                .frame(width: TimelineStyle.labelWidth, alignment: .leading)
            TimelineTrack(account: account, lanes: lanes, scale: scale, range: range, now: now)
        }
        .frame(height: height)
        .opacity(account.state == .disabled ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: account.label))
        .accessibilityValue(Text(verbatim: spokenSummary(lanes)))
    }

    private func spokenSummary(_ lanes: [TimelineLane]) -> String {
        var parts = [String(localized: account.state.label)]
        if let block = account.block(at: now) {
            parts.append(block.until.map { String(localized: "Blocked until \(ResetClock.string($0, now: now))") } ?? String(localized: "Account blocked"))
        }
        if lanes.isEmpty {
            parts.append(String(localized: TimelineTrack.emptyNote(account: account, scale: scale, now: now)))
        }
        parts += lanes.map(spokenLane)
        return parts.joined(separator: ", ")
    }

    private func spokenLane(_ lane: TimelineLane) -> String {
        let title = lane.label ?? String(localized: lane.window.label)
        var parts = [String(localized: "\(title) \(HeadroomStyle.percentText(lane.remainingPercent)) left")]
        if let current = lane.current {
            parts.append(String(localized: "resets \(ResetClock.string(current.end, now: now))"))
        }
        if let next = lane.nextWindow(after: account.block(for: lane.barID, at: now)) {
            parts.append(String(localized: "Next window \(ResetClock.string(next.start, now: now))"))
        }
        if let status = lane.statusWithoutResetTime {
            parts.append(String(localized: status))
        }
        return parts.joined(separator: ", ")
    }

    private func labels(_ lanes: [TimelineLane]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(account.state.color)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(Text(account.state.label))
                Text(verbatim: account.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: account.label))
            }
            .frame(height: TimelineStyle.nameHeight)
            ForEach(lanes) { lane in
                HStack(spacing: 4) {
                    lane.title
                    Text(HeadroomStyle.percentText(lane.remainingPercent))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                        .foregroundStyle(HeadroomStyle.color(forRemaining: lane.remainingPercent))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: TimelineStyle.laneHeight)
            }
        }
        .padding(.leading, 2)
    }
}

extension TimelineLane {
    var title: Text {
        label.map { Text(verbatim: $0) } ?? Text(window.label)
    }

    var statusWithoutResetTime: LocalizedStringResource? {
        guard current == nil else { return nil }
        if resetPassed { return "Reset passed" }
        if startsOnUse { return "Starts on use" }
        return "No reset time reported"
    }
}

private struct TimelineTrack: View {
    let account: AccountSummary
    let lanes: [TimelineLane]
    let scale: TimelineScale
    let range: DateInterval
    let now: Date

    var body: some View {
        GeometryReader { proxy in
            let mapper = TimelineMapper(range: range, width: proxy.size.width)
            let color = ProviderStyle.color(account.provider)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1.5, height: proxy.size.height)
                    .offset(x: mapper.x(now))
                if let block = account.block(at: now), let span = mapper.span(DateInterval(start: now, end: max(now, block.until ?? range.end))) {
                    BlockedStripes(color: .orange)
                        .frame(width: span.width, height: 4)
                        .clipShape(.capsule)
                        .offset(x: span.x, y: TimelineStyle.nameHeight - 7)
                        .help(block.until.map { Text("Blocked until \(ResetClock.text($0))") } ?? Text("Account blocked"))
                }
                if lanes.isEmpty {
                    Text(Self.emptyNote(account: account, scale: scale, now: now))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .offset(x: 6, y: TimelineStyle.nameHeight + 4)
                }
                ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                    laneView(lane, mapper: mapper, color: color)
                        .offset(y: TimelineStyle.nameHeight + CGFloat(index) * TimelineStyle.laneHeight + 2)
                }
            }
        }
    }

    static func emptyNote(account: AccountSummary, scale: TimelineScale, now: Date) -> LocalizedStringResource {
        if account.state == .disabled { return "Disabled, not counted" }
        if scale == .fiveHour, account.fiveHourWindow(at: now) == .notReported { return "No 5-hour window running" }
        return "No window reported"
    }

    @ViewBuilder
    private func laneView(_ lane: TimelineLane, mapper: TimelineMapper, color: Color) -> some View {
        let barHeight = TimelineStyle.laneHeight - 5
        ZStack(alignment: .topLeading) {
            if let current = lane.current, let span = mapper.span(current) {
                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(BoardStyle.cardBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: barHeight / 2).fill(color.opacity(0.32))
                    }
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: barHeight / 2)
                            .fill(color.opacity(0.55))
                            .frame(width: max(0, min(span.width, mapper.x(now) - span.x)))
                    }
                    .overlay(alignment: .leading) {
                        Text("\(HeadroomStyle.percentText(lane.remainingPercent)) left · \(ResetClock.text(current.end))")
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                    }
                    .clipShape(.rect(cornerRadius: barHeight / 2))
                    .frame(width: span.width, height: barHeight)
                    .offset(x: span.x)
            }
            if let next = lane.nextWindow(after: account.block(for: lane.barID, at: now)), let span = mapper.span(next) {
                upcoming(width: span.width, height: barHeight, color: color) {
                    Text(next.start, format: ResetClock.format(next.start, now: now))
                }
                .offset(x: span.x)
            }
            if let status = lane.statusWithoutResetTime {
                if let pending = lane.windowStartingAfter(account.block(for: lane.barID, at: now), now: now), let span = mapper.span(pending) {
                    upcoming(width: span.width, height: barHeight, color: color) {
                        Text(status)
                    }
                    .offset(x: span.x)
                } else {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(height: barHeight)
                        .offset(x: mapper.x(now) + 6)
                }
            }
        }
    }

    private func upcoming(width: CGFloat, height: CGFloat, color: Color, @ViewBuilder label: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .strokeBorder(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .overlay(alignment: .leading) {
                label()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
            .clipShape(.rect(cornerRadius: height / 2))
            .frame(width: width, height: height)
    }
}

private struct TimelineLegend: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { items }
            VStack(alignment: .leading, spacing: 4) { items }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var items: some View {
        Label {
            Text("Current window, elapsed part highlighted")
        } icon: {
            Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 18, height: 7)
        }
        Label {
            Text("Next window")
        } icon: {
            Capsule().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 18, height: 7)
        }
        Label {
            Text("Account blocked")
        } icon: {
            BlockedStripes(color: .orange).frame(width: 18, height: 5).clipShape(.capsule)
        }
        Label {
            Text("Now")
        } icon: {
            Rectangle().fill(Color.accentColor).frame(width: 2, height: 10)
        }
    }
}
