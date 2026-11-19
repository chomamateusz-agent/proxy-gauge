import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

extension OverviewLayout {
    var title: LocalizedStringResource {
        switch self {
        case .answerFirst: "Answer first"
        case .compactRows: "Compact rows"
        case .accountsStrip: "Accounts strip"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .answerFirst: "One big number per provider: what you can use now and when it grows."
        case .compactRows: "Every window as a short bar, with one line on who comes back when."
        case .accountsStrip: "One column per account, so you see at once which one is blocked and until when."
        }
    }

    var cardMinWidth: CGFloat {
        switch self {
        case .answerFirst, .compactRows: BoardStyle.tileMinWidth
        case .accountsStrip: 360
        }
    }
}

extension QuotaWindow {
    var shortLabel: LocalizedStringResource {
        switch self {
        case .session5h: LocalizedStringResource("gain.five-hour", defaultValue: "5-hour")
        case .weekly: "weekly"
        case .weeklyModel: LocalizedStringResource(stringLiteral: modelDisplayName ?? "")
        case .daily: "daily"
        case .monthly: "monthly"
        case .minutes(let minutes): "\(minutes)-minute window"
        case .other(let id): LocalizedStringResource(stringLiteral: id)
        }
    }
}

enum OverviewWording {
    static func names(_ names: [String]) -> String {
        names.count <= ProviderOverview.namedAccountsLimit
            ? names.formatted(.list(type: .and))
            : String(localized: "\(names.count) accounts")
    }

    static func windowName(_ barID: String, in pool: ProviderPool) -> String {
        pool.windows.first { $0.barID == barID }?.label ?? String(localized: QuotaWindow(barID: barID).shortLabel)
    }

    static func gains(_ comeback: Comeback, in pool: ProviderPool) -> String? {
        let parts = comeback.gains.map { gain in
            String(localized: "+\(HeadroomStyle.percentText(gain.percent)) \(windowName(gain.barID, in: pool))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func lead(_ comeback: Comeback) -> String {
        let who = names(comeback.accounts)
        switch comeback.kind {
        case .accountsBack:
            guard let at = comeback.at else { return String(localized: "\(who) blocked, no end time reported") }
            return String(localized: "\(who): back at \(ResetClock.string(at))")
        case .windowsReset:
            guard let at = comeback.at else { return who }
            return String(localized: "\(who): reset at \(ResetClock.string(at))")
        case .needsSignIn:
            return String(localized: "\(who) needs a new sign-in")
        case .blockedWithoutEnd:
            return String(localized: "\(who) blocked, no end time reported")
        }
    }

    static func headlineAnswer(_ comeback: Comeback) -> String {
        guard let at = comeback.at, let gain = comeback.gains.first else { return lead(comeback) }
        let amount = HeadroomStyle.percentText(gain.percent)
        let who = names(comeback.accounts)
        return switch comeback.kind {
        case .accountsBack: String(localized: "+\(amount) at \(ResetClock.string(at)) · \(who) back")
        case .windowsReset, .needsSignIn, .blockedWithoutEnd: String(localized: "+\(amount) at \(ResetClock.string(at)) · window reset for \(who)")
        }
    }

    static func windowNote(_ window: PooledWindow, in overview: ProviderOverview) -> String? {
        var parts: [String] = []
        let missing = overview.accountsWithoutData(in: window.barID)
        if !missing.isEmpty {
            parts.append(String(localized: "\(names(missing)): no data"))
        } else if window.unknownAccounts > 0 {
            parts.append(String(localized: "Accounts without data: \(window.unknownAccounts)"))
        }
        if window.accountsCountedAsFull > 0 {
            parts.append(String(localized: "+\(window.accountsCountedAsFull) idle"))
        }
        if window.accountsWithoutRunningWindow > 0 {
            parts.append(String(localized: "\(window.accountsWithoutRunningWindow) left out"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func windowSentence(_ window: PooledWindow) -> String {
        let title = window.label ?? String(localized: window.window.label)
        let remaining = HeadroomStyle.percentText(window.remainingPercent)
        let capacity = HeadroomStyle.percentText(window.capacityPercent)
        guard window.hasBlockedQuota else {
            return String(localized: "\(title): \(remaining) of \(capacity) left.")
        }
        return String(localized: "\(title): \(remaining) of \(capacity) left, usable now \(HeadroomStyle.percentText(window.usablePercent)), \(HeadroomStyle.percentText(window.blockedPercent)) blocked.")
    }
}

extension Comeback.Kind {
    var symbol: String {
        switch self {
        case .accountsBack, .blockedWithoutEnd: "hourglass"
        case .windowsReset: "clock"
        case .needsSignIn: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .accountsBack, .blockedWithoutEnd: .orange
        case .windowsReset: .secondary
        case .needsSignIn: .red
        }
    }
}

struct StateChipRow: View {
    let counts: [StateCount]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 4) { chips }
        }
    }

    private var chips: some View {
        ForEach(counts, id: \.self) { count in
            StateCountChip(count: count)
        }
    }
}

struct StateCountChip: View {
    let count: StateCount

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: count.state.symbol)
                .imageScale(.small)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(count.state.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(count.state.color.opacity(0.13), in: .capsule)
        .fixedSize()
    }

    private var text: Text {
        switch count.state {
        case .active: Text("\(count.count) active")
        case .cooldown: Text("\(count.count) cooling down")
        case .disabled: Text("\(count.count) disabled")
        case .error: Text("\(count.count) error")
        }
    }
}

struct ProviderCardHeader: View {
    let overview: ProviderOverview
    var showsChips = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                name
                Spacer(minLength: 6)
                if showsChips { StateChipRow(counts: overview.stateCounts).fixedSize() }
            }
            VStack(alignment: .leading, spacing: 6) {
                name
                if showsChips { StateChipRow(counts: overview.stateCounts) }
            }
        }
    }

    private var name: some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: overview.pool.provider, size: 28)
            Text(verbatim: ProviderCatalog.displayName(overview.pool.provider))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ComebackLine: View {
    let overview: ProviderOverview

    var body: some View {
        if let comeback = overview.comeback {
            let lead = OverviewWording.lead(comeback)
            let gains = OverviewWording.gains(comeback, in: overview.pool)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    icon(comeback)
                    Text(verbatim: lead).fontWeight(.semibold)
                    Spacer(minLength: 6)
                    if let gains { Text(verbatim: gains).foregroundStyle(.secondary) }
                }
                .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    icon(comeback)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: lead).fontWeight(.semibold)
                        if let gains { Text(verbatim: gains).foregroundStyle(.secondary) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.subheadline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: [lead, gains].compactMap(\.self).joined(separator: ", ")))
        } else if let next = overview.pool.nextIncreaseAt, next > .now {
            Label {
                Text("More at \(ResetClock.text(next))")
            } icon: {
                Image(systemName: "clock")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func icon(_ comeback: Comeback) -> some View {
        Image(systemName: comeback.kind.symbol)
            .foregroundStyle(comeback.kind.tint)
            .accessibilityHidden(true)
    }
}

struct NoQuotaDataReason: View {
    let overview: ProviderOverview
    let canRefreshLimits: Bool

    var body: some View {
        Label {
            text.fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
    }

    private var signIn: [String] { overview.accountsNeedingSignIn }

    private var fetchable: Bool {
        canRefreshLimits && ActiveRefreshPolicy.isSupported(overview.pool.provider)
    }

    private var text: Text {
        if overview.pool.accounts == 0 {
            Text("Every account of this provider is disabled.")
        } else if !signIn.isEmpty {
            Text(verbatim: String(localized: "\(OverviewWording.names(signIn)) needs a new sign-in"))
        } else if fetchable {
            Text("Fetch it with Refresh limits")
        } else {
            Text("No quota data reported yet")
        }
    }

    private var symbol: String {
        if overview.pool.accounts == 0 { return "pause.circle" }
        if !signIn.isEmpty { return "exclamationmark.triangle.fill" }
        return fetchable ? "arrow.triangle.2.circlepath.circle" : "questionmark.circle"
    }

    private var tint: Color {
        signIn.isEmpty ? .secondary : .red
    }
}

struct SlotBar: View {
    let window: PooledWindow
    var height: CGFloat = 8

    var body: some View {
        PooledCapacityBar(window: window, height: height)
            .overlay {
                GeometryReader { proxy in
                    let slots = max(1, window.accountSlots)
                    ForEach(1..<slots, id: \.self) { index in
                        Rectangle()
                            .fill(BoardStyle.cardBackground)
                            .frame(width: 2, height: height)
                            .offset(x: proxy.size.width * CGFloat(index) / CGFloat(slots) - 1)
                    }
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

struct CompactWindowRow: View {
    let window: PooledWindow
    let overview: ProviderOverview
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 96
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: 6)
                    amount
                }
                SlotBar(window: window)
            } else {
                HStack(spacing: 10) {
                    title.frame(width: labelWidth, alignment: .leading)
                    SlotBar(window: window)
                    amount
                }
            }
            if let note = OverviewWording.windowNote(window, in: overview) {
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [OverviewWording.windowSentence(window), OverviewWording.windowNote(window, in: overview)].compactMap(\.self).joined(separator: " ")))
    }

    private var title: some View {
        window.title
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var amount: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: HeadroomStyle.percentText(window.remainingPercent))
                .font(.subheadline.monospacedDigit().weight(.semibold))
            Text("of \(HeadroomStyle.percentText(window.capacityPercent))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

struct CompactRowsCard: View {
    let overview: ProviderOverview
    let canRefreshLimits: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderCardHeader(overview: overview)
            if overview.pool.windows.isEmpty {
                NoQuotaDataReason(overview: overview, canRefreshLimits: canRefreshLimits)
                    .font(.subheadline)
            } else {
                CompactWindowRows(overview: overview)
                Divider()
                ComebackLine(overview: overview)
            }
        }
        .boardCard()
    }
}

struct CompactWindowRows: View {
    let overview: ProviderOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(overview.pool.windows) { window in
                CompactWindowRow(window: window, overview: overview)
            }
        }
    }
}

struct AnswerFirstCard: View {
    let overview: ProviderOverview
    let canRefreshLimits: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProviderCardHeader(overview: overview)
            if let window = overview.headline {
                let note = OverviewWording.windowNote(window, in: overview)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usable now · \(window.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) { bigNumber(window) }
                        VStack(alignment: .leading, spacing: 0) { bigNumber(window) }
                    }
                    if let note {
                        Text(verbatim: note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Usable now in the \(window.title) window: \(HeadroomStyle.percentText(window.usablePercent)) of \(HeadroomStyle.percentText(window.capacityPercent))"))
                .accessibilityValue(Text(verbatim: note ?? ""))
                answer
            } else {
                Text("No data")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                NoQuotaDataReason(overview: overview, canRefreshLimits: canRefreshLimits)
                    .font(.subheadline)
            }
        }
        .boardCard()
    }

    @ViewBuilder
    private func bigNumber(_ window: PooledWindow) -> some View {
        Text(verbatim: HeadroomStyle.percentText(window.usablePercent))
            .font(.largeTitle.weight(.bold).monospacedDigit())
            .foregroundStyle(window.color)
        Text("of \(HeadroomStyle.percentText(window.capacityPercent))")
            .font(.title3.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var answer: some View {
        if let comeback = overview.headlineComeback {
            Label {
                Text(verbatim: OverviewWording.headlineAnswer(comeback))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: comeback.kind == .accountsBack ? "arrow.up.circle.fill" : comeback.kind.symbol)
                    .foregroundStyle(comeback.kind == .accountsBack ? .green : comeback.kind.tint)
            }
            .font(.subheadline)
        }
    }
}

struct AccountsStripCard: View {
    let overview: ProviderOverview
    let canRefreshLimits: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderCardHeader(overview: overview, showsChips: !overview.hasAccountColumns)
            if overview.hasAccountColumns {
                AccountMatrix(overview: overview)
                Divider()
                ComebackLine(overview: overview)
            } else if !overview.pool.windows.isEmpty {
                CompactWindowRows(overview: overview)
                Divider()
                ComebackLine(overview: overview)
            } else {
                NoQuotaDataReason(overview: overview, canRefreshLimits: canRefreshLimits)
                    .font(.subheadline)
            }
        }
        .boardCard()
    }
}

struct ProviderOverviewCard: View {
    let overview: ProviderOverview
    let layout: OverviewLayout
    let session: ServerSession

    var body: some View {
        NavigationLink {
            ProviderDetailView(session: session, provider: overview.pool.provider)
        } label: {
            card.contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var card: some View {
        switch layout {
        case .answerFirst: AnswerFirstCard(overview: overview, canRefreshLimits: session.supportsLimitsRefresh)
        case .compactRows: CompactRowsCard(overview: overview, canRefreshLimits: session.supportsLimitsRefresh)
        case .accountsStrip: AccountsStripCard(overview: overview, canRefreshLimits: session.supportsLimitsRefresh)
        }
    }
}
