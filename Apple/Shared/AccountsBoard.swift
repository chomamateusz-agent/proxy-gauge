import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

enum BoardStyle {
    static let cornerRadius: CGFloat = 12
    static let spacing: CGFloat = 12
    static let cardMinWidth: CGFloat = 280
    static let compactCardMinWidth: CGFloat = 210
    static let tileMinWidth: CGFloat = 280
    static let compactTileMinWidth: CGFloat = 210
    static let providersForCompactTiles = 4

    static var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    static var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }
}

struct BoardCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(BoardStyle.cardBackground, in: .rect(cornerRadius: BoardStyle.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: BoardStyle.cornerRadius)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            }
    }
}

extension View {
    func boardCard() -> some View {
        modifier(BoardCard())
    }
}

struct EqualHeightGrid: Layout {
    var minItemWidth: CGFloat
    var spacing: CGFloat = BoardStyle.spacing

    private func columns(for width: CGFloat, count: Int) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, min(count, Int((width + spacing) / (minItemWidth + spacing))))
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (itemWidth: CGFloat, heights: [CGFloat], columns: Int) {
        let columns = columns(for: width, count: subviews.count)
        let itemWidth = width.isFinite ? (width - spacing * CGFloat(columns - 1)) / CGFloat(columns) : minItemWidth
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }
                .max() ?? 0
        }
        return (itemWidth, heights, columns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? minItemWidth
        let layout = rows(subviews, width: width)
        let height = layout.heights.reduce(0, +) + spacing * CGFloat(max(0, layout.heights.count - 1))
        return CGSize(width: width.isFinite ? width : layout.itemWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for (row, height) in layout.heights.enumerated() {
            for column in 0..<layout.columns {
                let index = row * layout.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (layout.itemWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: layout.itemWidth, height: height))
            }
            y += height + spacing
        }
    }
}

struct AccountsLayoutPicker: View {
    @Binding var storedLayout: String
    let compactWidth: Bool

    var body: some View {
        Picker("Layout", selection: Binding(
            get: { AccountsLayout.resolve(storedLayout, compactWidth: compactWidth) },
            set: { storedLayout = $0.rawValue }
        )) {
            ForEach(AccountsLayout.available(compactWidth: compactWidth)) { layout in
                Label { Text(layout.title) } icon: { Image(systemName: layout.symbol) }
                    .tag(layout)
            }
        }
        #if os(macOS)
        .pickerStyle(.segmented)
        #else
        .pickerStyle(.menu)
        #endif
        .help(Text("Layout"))
    }
}

extension AccountsLayout {
    var title: LocalizedStringResource {
        switch self {
        case .cards: "Cards"
        case .list: "List"
        case .table: "Table"
        }
    }

    var symbol: String {
        switch self {
        case .cards: "square.grid.2x2"
        case .list: "list.bullet"
        case .table: "tablecells"
        }
    }
}

struct AccountsBoard: View {
    let accounts: [AccountSummary]
    let layout: AccountsLayout
    var session: ServerSession?
    var cardMinWidth = BoardStyle.cardMinWidth
    @State private var limitsRequest: LimitsRefreshRequest?

    var body: some View {
        if let session, session.supportsLimitsRefresh {
            board.limitsRefreshSheet(session: session, request: $limitsRequest)
        } else {
            board
        }
    }

    @ViewBuilder
    private var board: some View {
        switch layout {
        case .cards:
            cards
        case .list:
            VStack(spacing: 0) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider() }
                    linked(account) {
                        AccountSummaryRow(account: account)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(BoardStyle.cardBackground, in: .rect(cornerRadius: BoardStyle.cornerRadius))
        case .table:
            ViewThatFits(in: .horizontal) {
                AccountsTable(accounts: accounts, session: session) { limitsRequest = $0 }
                VStack(alignment: .leading, spacing: BoardStyle.spacing) {
                    Label("The window is too narrow for every column, so the accounts are shown as cards. Widen the window to see the table.", systemImage: "arrow.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    cards
                }
            }
        }
    }

    private var cards: some View {
        EqualHeightGrid(minItemWidth: cardMinWidth) {
            ForEach(accounts) { account in
                linked(account) { AccountCard(account: account) }
            }
        }
    }

    @ViewBuilder
    private func linked(_ account: AccountSummary, @ViewBuilder label: () -> some View) -> some View {
        if let session, session.profile.authMode == .management {
            NavigationLink {
                AccountDetailView(session: session, credentialID: account.id)
            } label: {
                label()
            }
            .buttonStyle(.plain)
            .contextMenu {
                RefreshLimitsMenuItem(session: session, account: account) { limitsRequest = $0 }
            }
        } else {
            label()
        }
    }
}

struct RefreshLimitsMenuItem: View {
    let session: ServerSession
    let account: AccountSummary
    let request: (LimitsRefreshRequest) -> Void

    var body: some View {
        if session.supportsLimitsRefresh {
            Button("Refresh limits", systemImage: "arrow.triangle.2.circlepath.circle") {
                request(LimitsRefreshRequest(credentialIDs: [account.id]))
            }
            .disabled(session.refreshingLimits.contains(account.id))
        }
    }
}

struct AccountCard: View {
    let account: AccountSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AccountHeader(account: account, badgeSize: 26)
            AccountNotes(account: account)
            if account.bars.isEmpty {
                Text("No quota data reported yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            AccountQuotaBars(account: account, compact: true)
        }
        .boardCard()
        .opacity(account.state == .disabled ? 0.65 : 1)
    }
}

private struct AccountHeader: View {
    let account: AccountSummary
    let badgeSize: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ProviderBadge(provider: account.provider, size: badgeSize)
                VStack(alignment: .leading, spacing: 2) {
                    label.fixedSize()
                    providerAndPlan
                }
                Spacer(minLength: 4)
                StateChip(state: account.state)
            }
            HStack(alignment: .top, spacing: 8) {
                ProviderBadge(provider: account.provider, size: badgeSize)
                VStack(alignment: .leading, spacing: 4) {
                    label.fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            providerAndPlan.fixedSize()
                            StateChip(state: account.state)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            providerAndPlan
                            StateChip(state: account.state)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var label: some View {
        Text(verbatim: account.label)
            .font(.subheadline.weight(.semibold))
            .help(Text(verbatim: account.label))
    }

    private var providerAndPlan: some View {
        ProviderAndPlan(account: account)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct ProviderAndPlan: View {
    let account: AccountSummary

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: ProviderCatalog.displayName(account.provider))
            if let plan = account.plan {
                PlanChip(plan: plan)
            }
        }
    }
}

private struct AccountNotes: View {
    let account: AccountSummary

    var body: some View {
        let now = Date.now
        if let until = account.blockedUntil, until > now {
            CooldownNote(until: until)
                .font(.caption)
        }
        if account.requiresSignIn {
            Label("Needs a new sign-in", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.red)
        }
        if account.state == .error, let message = account.statusMessage {
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(account.modelCooldowns.prefix(AccountNotes.listedModelCooldowns), id: \.self) { cooldown in
            ModelCooldownNote(cooldown: cooldown)
                .font(.caption)
        }
        if account.modelCooldowns.count > AccountNotes.listedModelCooldowns {
            Text("More models cooling down: \(account.modelCooldowns.count - AccountNotes.listedModelCooldowns)")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let balance = account.creditsBalance {
            Text("Credits: \(balance.formatted(.number.precision(.fractionLength(0...2))))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ProviderCheckNotes(account: account)
            .font(.caption)
    }

    static let listedModelCooldowns = 3
}

private struct AccountQuotaBars: View {
    let account: AccountSummary
    var compact = false

    var body: some View {
        if account.fiveHourWindow(at: .now) == .notReported {
            NoFiveHourWindowRow()
        }
        ForEach(account.bars) { bar in
            QuotaBarRow(bar: bar, provider: account.provider, compact: compact)
        }
    }
}

struct AccountSummaryRow: View {
    let account: AccountSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AccountHeader(account: account, badgeSize: 22)
            AccountNotes(account: account)
            AccountQuotaBars(account: account)
        }
        .opacity(account.state == .disabled ? 0.65 : 1)
    }
}

struct AccountsTable: View {
    let accounts: [AccountSummary]
    var session: ServerSession?
    var onRefreshLimits: (LimitsRefreshRequest) -> Void = { _ in }

    var body: some View {
        grid
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BoardStyle.cardBackground, in: .rect(cornerRadius: BoardStyle.cornerRadius))
    }

    private var grid: some View {
        let windows = AccountSummary.windowIDs(accounts)
        let now = Date.now
        return Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text("Account")
                Text("State")
                ForEach(windows, id: \.self) { window in
                    columnTitle(window)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(accounts) { account in
                Divider()
                GridRow {
                    nameCell(account)
                    stateCell(account)
                    ForEach(windows, id: \.self) { window in
                        if let bar = account.bar(window) {
                            TableQuotaCell(bar: bar, provider: account.provider)
                        } else if window == FiveHourWindowState.barID, account.fiveHourWindow(at: now) == .notReported {
                            Text("No 5-hour window")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(verbatim: "–")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text("Unknown"))
                        }
                    }
                }
                .opacity(account.state == .disabled ? 0.65 : 1)
            }
        }
    }

    private func columnTitle(_ window: String) -> Text {
        accounts.lazy.compactMap { $0.bar(window)?.label }.first.map { Text(verbatim: $0) } ?? Text(QuotaWindow(barID: window).label)
    }

    @ViewBuilder
    private func nameCell(_ account: AccountSummary) -> some View {
        let label = HStack(alignment: .top, spacing: 8) {
            ProviderBadge(provider: account.provider, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: account.label)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                ProviderAndPlan(account: account)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProviderCheckNotes(account: account)
                    .font(.caption2)
            }
        }
        .frame(minWidth: 180, maxWidth: 320, alignment: .leading)
        if let session, session.profile.authMode == .management {
            NavigationLink {
                AccountDetailView(session: session, credentialID: account.id)
            } label: {
                label.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .contextMenu {
                RefreshLimitsMenuItem(session: session, account: account, request: onRefreshLimits)
            }
        } else {
            label
        }
    }

    private func stateCell(_ account: AccountSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            StateChip(state: account.state)
            if let until = account.blockedUntil, until > .now {
                Text("until \(ResetClock.text(until))")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if account.requiresSignIn {
                Text("Needs a new sign-in")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if account.state == .error, let message = account.statusMessage {
                Text(verbatim: message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(Text(verbatim: message))
            }
            ForEach(account.modelCooldowns.prefix(2), id: \.self) { cooldown in
                modelCooldownLine(cooldown)
            }
            if account.modelCooldowns.count > 2 {
                Text("More models cooling down: \(account.modelCooldowns.count - 2)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(minWidth: 110, maxWidth: 200, alignment: .leading)
    }

    private func modelCooldownLine(_ cooldown: ModelCooldown) -> some View {
        Group {
            if let until = cooldown.until, until > .now {
                Text("\(cooldown.model) until \(ResetClock.text(until))")
            } else {
                Text("\(cooldown.model) cooling down")
            }
        }
        .font(.caption2)
        .foregroundStyle(.orange)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(Text(verbatim: cooldown.model))
    }
}

private struct TableQuotaCell: View {
    let bar: QuotaBar
    let provider: String

    var body: some View {
        let now = Date.now
        let remaining = bar.remainingPercent(at: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                HeadroomStyle.remainingText(remaining)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(remaining == nil ? .secondary : HeadroomStyle.color(forRemaining: remaining))
                if bar.isFromProvider {
                    ProviderSourceMark(sampledAt: bar.sampledAt)
                }
                if bar.isAtLimit(at: now) {
                    Text("At limit")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                } else if bar.startsOnUse(provider: provider, at: now) {
                    Text("Starts on use")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            RemainingBar(remainingPercent: remaining, height: 5)
            if let resetsAt = bar.resetsAt {
                Group {
                    if resetsAt > now {
                        Text("\(ResetClock.text(resetsAt)) · in \(Text(resetsAt, style: .relative))")
                    } else {
                        Text("Reset at \(ResetClock.text(resetsAt))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bar.title)
        .accessibilityValue(accessibilityValue(remaining: remaining, now: now))
    }

    private func accessibilityValue(remaining: Double?, now: Date) -> Text {
        guard let resetsAt = bar.resetsAt, resetsAt > now else { return HeadroomStyle.remainingText(remaining) }
        return Text("\(HeadroomStyle.remainingText(remaining)), resets \(ResetClock.text(resetsAt))")
    }
}
