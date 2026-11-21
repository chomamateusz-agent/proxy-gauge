import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct PoolSegmentsBar: View {
    let segments: [PoolSegment]
    var height: CGFloat = 8

    var body: some View {
        HStack(spacing: 4) {
            ForEach(segments) { segment in
                PoolSegmentCell(segment: segment, height: height)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct PoolSegmentCell: View {
    let segment: PoolSegment
    let height: CGFloat

    var body: some View {
        if segment.isStub {
            Capsule()
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                .foregroundStyle(.secondary.opacity(0.7))
        } else {
            ShareBar(
                remainingPercent: segment.remainingPercent,
                fill: segment.isBlocked ? .blocked : segment.kind == .idle ? .idle : .level,
                height: height
            )
        }
    }
}

struct ShareBar: View {
    enum Fill {
        case level
        case idle
        case blocked
    }

    let remainingPercent: Double?
    var fill = Fill.level
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(1, max(0, (remainingPercent ?? 0) / 100))
            let width = fraction > 0 ? max(height, proxy.size.width * fraction) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(HeadroomStyle.track)
                filled
                    .frame(width: width)
                    .clipShape(.capsule)
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private var filled: some View {
        switch fill {
        case .level: Rectangle().fill(HeadroomStyle.color(forRemaining: remainingPercent).gradient)
        case .idle: Rectangle().fill(HeadroomStyle.color(forRemaining: 100).opacity(0.45))
        case .blocked: BlockedStripes(color: .gray)
        }
    }
}

struct HatchSwatch: View {
    var body: some View {
        BlockedStripes(color: .gray)
            .frame(width: 14, height: 9)
            .clipShape(.rect(cornerRadius: 2))
            .accessibilityHidden(true)
    }
}

struct PoolWindowRow: View {
    let window: PooledWindow
    let overview: ProviderOverview
    var order: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                window.title
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: HeadroomStyle.percentText(window.remainingPercent))
                        .font(.title3.weight(.bold).monospacedDigit())
                    Text("of \(HeadroomStyle.percentText(window.capacityPercent))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }
            PoolSegmentsBar(segments: overview.segments(window.barID, order: order))
            PoolWindowCaption(window: window, overview: overview)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: OverviewWording.windowSentence(window)))
    }
}

struct PoolWindowCaption: View {
    let window: PooledWindow
    let overview: ProviderOverview
    @State private var showsNotes = false

    private var notes: PoolNotes { PoolNotes(window: window, overview: overview) }

    var body: some View {
        let notes = notes
        if window.hasBlockedQuota || !notes.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    blockedPart(short: false)
                    notesButton(notes, short: false)
                }
                HStack(spacing: 6) {
                    blockedPart(short: true)
                    notesButton(notes, short: true)
                }
                FlowLayout(spacing: 5) {
                    if window.hasBlockedQuota {
                        Text("\(HeadroomStyle.percentText(window.usablePercent)) usable")
                        HStack(spacing: 5) {
                            HatchSwatch()
                            Text("\(HeadroomStyle.percentText(window.blockedPercent)) blocked")
                                .foregroundStyle(.secondary)
                        }
                    }
                    notesButton(notes, short: true)
                }
            }
            .font(.footnote)
            .lineLimit(1)
            .popover(isPresented: $showsNotes) {
                PoolNotesPopover(notes: notes)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    @ViewBuilder
    private func blockedPart(short: Bool) -> some View {
        if window.hasBlockedQuota {
            HStack(spacing: 5) {
                Text(short ? "\(HeadroomStyle.percentText(window.usablePercent)) usable" : "\(HeadroomStyle.percentText(window.usablePercent)) usable now")
                Text(verbatim: "·").foregroundStyle(.secondary).accessibilityHidden(true)
                HatchSwatch()
                Text("\(HeadroomStyle.percentText(window.blockedPercent)) blocked")
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private func notesButton(_ notes: PoolNotes, short: Bool) -> some View {
        if !notes.isEmpty {
            HStack(spacing: 5) {
                if window.hasBlockedQuota {
                    Text(verbatim: "·").foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Button {
                    showsNotes = true
                } label: {
                    Text(verbatim: notes.summary(short: short))
                        .underline(pattern: .dot)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
            .fixedSize()
        }
    }
}

struct PoolNotes {
    var idle: [String]
    var leftOut: [String]
    var noData: [String]
    var window: QuotaWindow

    init(window: PooledWindow, overview: ProviderOverview) {
        self.window = window.window
        idle = overview.accounts(in: window.barID) { $0.value == .idleCountedAsFull }
        leftOut = overview.accounts(in: window.barID) { $0.value == .leftOutWithoutRunningWindow }
        noData = overview.accounts(in: window.barID) { $0.value == .unknown }
    }

    var isEmpty: Bool { idle.isEmpty && leftOut.isEmpty && noData.isEmpty }

    func summary(short: Bool) -> String {
        var parts: [String] = []
        if !idle.isEmpty { parts.append(String(localized: "+\(idle.count) idle")) }
        if !leftOut.isEmpty { parts.append(String(localized: "\(leftOut.count) left out")) }
        if !noData.isEmpty, !short || parts.isEmpty { parts.append(String(localized: "\(noData.count) without data")) }
        return parts.joined(separator: " · ")
    }
}

struct PoolNotesPopover: View {
    let notes: PoolNotes

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group(notes.idle, title: "Idle, counted as full", detail: "Not started yet, counts as full. Cooling accounts stay in the pool, hatched.")
            group(notes.leftOut, title: "Left out", detail: "No 5-hour reading at all, so the account is left out of this pool.")
            group(notes.noData, title: "Without data", detail: "Counted in the total, but no reading has arrived yet.")
        }
        .padding(18)
        .frame(width: 320, alignment: .leading)
    }

    @ViewBuilder
    private func group(_ names: [String], title: LocalizedStringResource, detail: LocalizedStringResource) -> some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: names.formatted(.list(type: .and)))
                    .font(.subheadline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StatusChipView: View {
    let chip: StatusChip

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: symbol)
                .imageScale(.small)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: .capsule)
        .fixedSize()
    }

    private var text: Text {
        switch chip.kind {
        case .state(.active): Text("\(chip.count) active")
        case .state(.cooldown): Text("\(chip.count) cooling down")
        case .state(.disabled): Text("\(chip.count) disabled")
        case .state(.error): Text("\(chip.count) error")
        case .needsSignIn: Text("\(chip.count) needs sign-in")
        }
    }

    private var color: Color {
        switch chip.kind {
        case .state(let state): state.color
        case .needsSignIn: .red
        }
    }

    private var symbol: String {
        switch chip.kind {
        case .state(let state): state.symbol
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        }
    }
}

struct StatusChipRow: View {
    let chips: [StatusChip]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(chips, id: \.self) { StatusChipView(chip: $0) }
        }
    }
}

struct ComebackFooter: View {
    let overview: ProviderOverview

    var body: some View {
        if let comeback = overview.comeback {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: comeback.kind.symbol)
                    .foregroundStyle(comeback.kind.tint)
                    .accessibilityHidden(true)
                Text(verbatim: OverviewWording.lead(comeback))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let gains = OverviewWording.gains(comeback, in: overview.pool) {
                    Text(verbatim: gains)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
        } else if let next = overview.pool.nextIncreaseAt, next > .now {
            Label {
                Text("More at \(ResetClock.text(next))")
            } icon: {
                Image(systemName: "clock")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

extension ServerSession {
    func cardOrderMode(routerOrder: Bool) -> CardOrderMode {
        guard supportsRouterOrder, routerOrder, let routerSettings else { return .stock }
        return .router(routerSettings)
    }

    func orderedAccounts(provider: String?, routerOrder: Bool, now: Date) -> [OrderedAccount] {
        let accounts = accountSummaries.filter { provider == nil || $0.provider == provider }
        return AccountOrder.ordered(accounts, mode: cardOrderMode(routerOrder: routerOrder), now: now)
    }
}

extension CardOrderMode {
    var caption: LocalizedStringResource {
        switch self {
        case .stock: "Usable first"
        case .router(let settings): settings.ranksByUseOrLose ? "Router order" : "List order"
        }
    }
}

struct RouterOrderStorage: DynamicProperty {
    @AppStorage private var stored: Bool

    init(serverID: UUID) {
        _stored = AppStorage(wrappedValue: ServerLab.routerOrderDefault, ServerLab.routerOrderKey(serverID: serverID))
    }

    var isOn: Bool { stored }

    var binding: Binding<Bool> { $stored }
}
