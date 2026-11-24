import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

enum PanelStyle {
    static let meterHeight: CGFloat = 5
    static let cardSpacing: CGFloat = 16
    #if os(macOS)
    static let cardInset: CGFloat = 12
    #else
    static let cardInset: CGFloat = 10
    #endif
    #if os(macOS)
    static let cardMinWidth: CGFloat = 210
    static let cardMaxWidth: CGFloat = 270
    #else
    static let cardMinWidth: CGFloat = 165
    static let cardMaxWidth: CGFloat = 300
    #endif
}

extension WindowSlot {
    var title: Text {
        if let label { return Text(verbatim: label) }
        return Text(holdsOnlyMonthlyReadings ? QuotaWindow.monthly.label : window.label)
    }
}

enum PanelDate {
    static func absolute(_ date: Date) -> String {
        date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).hour().minute())
    }

    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day(.twoDigits).month(.twoDigits))
    }
}

struct PanelMeter: View {
    let remainingPercent: Double?
    var height: CGFloat = PanelStyle.meterHeight

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(1, max(0, (remainingPercent ?? 0) / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(HeadroomStyle.track)
                if remainingPercent != nil, fraction > 0 {
                    Capsule()
                        .fill(HeadroomStyle.color(forRemaining: remainingPercent))
                        .frame(width: max(height, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct PanelSlotView<Foot: View>: View {
    let title: Text
    let remainingPercent: Double?
    var mark: AnyView?
    @ViewBuilder let foot: () -> Foot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                title
                    .font(.board(.footnote).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .allowsTightening(true)
                if let mark { mark }
                Spacer(minLength: 0)
                Text(verbatim: HeadroomStyle.percentText(remainingPercent))
                    .font(.board(.footnote).weight(.bold).monospacedDigit())
                    .foregroundStyle(remainingPercent == nil ? .secondary : .primary)
                    .fixedSize()
            }
            PanelMeter(remainingPercent: remainingPercent)
            foot()
                .font(.board(.footnote).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct SlotReadingRow: View {
    let reading: SlotReading
    var showsSource = false
    let now: Date

    var body: some View {
        PanelSlotView(title: reading.slot.title, remainingPercent: reading.remainingPercent, mark: sourceMark) {
            foot
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.slot.title + Text(verbatim: ", \(accessibilityValue)"))
    }

    private var sourceMark: AnyView? {
        guard showsSource, let bar = reading.bar, bar.isFromProvider else { return nil }
        return AnyView(ProviderSourceMark(sampledAt: bar.sampledAt))
    }

    @ViewBuilder
    private var foot: some View {
        if reading.startsOnFirstUse {
            Text("Starts on first use")
        } else if let resetsAt = reading.resetsAt {
            ViewThatFits(in: .horizontal) {
                Text(verbatim: "\(PanelDate.absolute(resetsAt)) · \(PanelDate.relative(resetsAt, now: now))")
                Text(verbatim: PanelDate.absolute(resetsAt))
            }
        } else {
            Text(verbatim: " ")
        }
    }

    private var accessibilityValue: String {
        guard reading.remainingPercent != nil else { return String(localized: "No data") }
        let left = String(localized: "\(HeadroomStyle.percentText(reading.remainingPercent)) left")
        if reading.startsOnFirstUse { return [left, String(localized: "Starts on first use")].joined(separator: ", ") }
        guard let resetsAt = reading.resetsAt else { return left }
        return [left, PanelDate.absolute(resetsAt), PanelDate.relative(resetsAt, now: now)].joined(separator: ", ")
    }
}

struct SlotPoolView: View {
    let pool: SlotPool
    let weighted: Bool

    var body: some View {
        PanelSlotView(title: pool.slot.title, remainingPercent: pool.remainingPercent) {
            Text(verbatim: caption)
        }
        .modifier(WeightedHelp(isOn: weighted))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pool.slot.title + Text(verbatim: ", \(accessibilityValue)"))
    }

    private var accessibilityValue: String {
        let left = pool.remainingPercent == nil ? String(localized: "No data") : String(localized: "\(HeadroomStyle.percentText(pool.remainingPercent)) left")
        return [left, caption].joined(separator: ", ")
    }

    private var caption: String {
        let covers = pool.total == 1 ? String(localized: "\(pool.covered) of 1 account") : String(localized: "\(pool.covered) of \(pool.total) accounts")
        return weighted && pool.covered > 0 ? "\(covers) · \(String(localized: "weighted by plan"))" : covers
    }
}

private struct WeightedHelp: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.help(Text("Weighted by plan size: Max 20x counts 20, Max 5x counts 5, Pro counts 1"))
        } else {
            content
        }
    }
}

struct PoolColumns: View {
    let pools: ProviderSlotPools
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var stacked: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 12) { columns }
        } else {
            HStack(alignment: .top, spacing: 24) { columns }
        }
    }

    private var columns: some View {
        ForEach(pools.pools) { pool in
            SlotPoolView(pool: pool, weighted: pools.weighted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ProviderSectionTitle: View {
    let provider: String
    let accounts: Int
    let loaded: Int
    var showsChevron = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                name
                counts
                Spacer(minLength: 4)
                chevron
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    name
                    Spacer(minLength: 4)
                    chevron
                }
                counts
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var name: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProviderBadge(provider: provider, size: 22)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(verbatim: ProviderCatalog.displayName(provider))
                .font(.board(.headline))
                .lineLimit(1)
        }
    }

    private var counts: some View {
        Text(verbatim: "\(String(localized: "\(accounts) accounts")) · \(String(localized: "\(loaded)/\(accounts) loaded"))")
            .font(.board(.footnote).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var chevron: some View {
        if showsChevron {
            Image(systemName: "chevron.right")
                .font(.board(.footnote).weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

struct ProviderPanelHeader<Extra: View>: View {
    let pools: ProviderSlotPools
    let overview: ProviderOverview?
    let mode: CardOrderMode
    let canRefreshLimits: Bool
    var showsChevron = false
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderSectionTitle(provider: pools.provider, accounts: pools.accounts, loaded: pools.loaded, showsChevron: showsChevron)
            if let note = mode.routerNote {
                Text(note)
                    .font(.board(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pools.hasAnyReading {
                PoolColumns(pools: pools)
            } else if let overview {
                NoQuotaDataReason(overview: overview, canRefreshLimits: canRefreshLimits)
                    .font(.board(.subheadline))
            }
            extra()
        }
        .boardCard()
    }
}

extension ProviderPanelHeader where Extra == EmptyView {
    init(pools: ProviderSlotPools, overview: ProviderOverview?, mode: CardOrderMode, canRefreshLimits: Bool, showsChevron: Bool = false) {
        self.init(pools: pools, overview: overview, mode: mode, canRefreshLimits: canRefreshLimits, showsChevron: showsChevron) { EmptyView() }
    }
}

extension CardOrderMode {
    var routerNote: LocalizedStringResource? {
        guard case .router(let settings) = self else { return nil }
        return settings.ranksByUseOrLose ? "Order: use-or-lose estimate for new sessions." : "Order: list order. Routing uses \(settings.strategy)."
    }
}

struct PageStatusLine: View {
    let status: AccountsStatus

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Capsule()
                .fill(.tint)
                .frame(width: 3)
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    accounts
                    separator
                    loaded
                    if status.needAttention > 0 {
                        separator
                        attention
                    }
                }
                .lineLimit(1)
                VStack(alignment: .leading, spacing: 2) {
                    if status.needAttention > 0 { attention }
                    accounts
                    loaded
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .font(.board(.footnote).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var accounts: some View {
        Text(verbatim: String(localized: "\(status.accounts) accounts"))
    }

    private var loaded: some View {
        Text(verbatim: String(localized: "\(status.loaded) loaded"))
            .foregroundStyle(status.loaded > 0 ? Color.green : Color.secondary)
    }

    private var attention: some View {
        Text(verbatim: String(localized: "\(status.needAttention) needs attention"))
            .foregroundStyle(.red)
    }

    private var separator: some View {
        Text(verbatim: "·").accessibilityHidden(true)
    }
}

struct ProviderFilterBar: View {
    let accounts: [AccountSummary]
    @Binding var selection: String

    static let all = ""

    var body: some View {
        let providers = AccountSummary.providers(accounts)
        if providers.count > 1 {
            Picker("Provider", selection: Binding(
                get: { AccountSummary.shownProvider(selection, in: accounts) ?? Self.all },
                set: { selection = $0 }
            )) {
                Text(verbatim: String(localized: "All \(accounts.count)")).tag(Self.all)
                ForEach(providers, id: \.self) { provider in
                    Text(verbatim: "\(ProviderCatalog.displayName(provider)) \(accounts.count { $0.provider == provider })").tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

extension AccountSummary {
    static func providers(_ accounts: [AccountSummary]) -> [String] {
        accounts.reduce(into: [String]()) { list, account in
            if !list.contains(account.provider) { list.append(account.provider) }
        }
    }

    static func shownProvider(_ filter: String, in accounts: [AccountSummary]) -> String? {
        let providers = providers(accounts)
        return providers.count > 1 && providers.contains(filter) ? filter : nil
    }
}
