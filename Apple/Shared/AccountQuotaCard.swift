import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

enum CardStatus: Equatable {
    case active
    case cooling(until: Date?, limitBarID: String? = nil)
    case limitReached(until: Date?, barID: String)
    case needsSignIn
    case error
    case disabled

    init(account: AccountSummary, now: Date) {
        if account.state == .disabled {
            self = .disabled
        } else if account.availability == .needsSignIn {
            self = .needsSignIn
        } else if let block = account.block(at: now) {
            switch block.reason {
            case .cooldown: self = .cooling(until: block.until)
            case .windowAtLimit(let barID) where account.state == .cooldown: self = .cooling(until: block.until, limitBarID: barID)
            case .windowAtLimit(let barID): self = .limitReached(until: block.until, barID: barID)
            case .signIn: self = .needsSignIn
            }
        } else {
            self = account.state == .error ? .error : .active
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .active: "Active"
        case .cooling: "Cooling down"
        case .limitReached: "Limit reached"
        case .needsSignIn: "Needs sign-in"
        case .error: "Error"
        case .disabled: "Disabled"
        }
    }

    var color: Color {
        switch self {
        case .active: .green
        case .cooling, .limitReached: .orange
        case .needsSignIn, .error: .red
        case .disabled: .gray
        }
    }

    var symbol: String {
        switch self {
        case .active: "checkmark.circle.fill"
        case .cooling, .limitReached: "hourglass"
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        case .error: "exclamationmark.triangle.fill"
        case .disabled: "pause.circle.fill"
        }
    }

    var backAt: Date? {
        switch self {
        case .cooling(let until, _), .limitReached(let until, _): until
        default: nil
        }
    }

    var limitBarID: String? {
        switch self {
        case .cooling(_, let barID): barID
        case .limitReached(_, let barID): barID
        default: nil
        }
    }

    var isBlocked: Bool {
        switch self {
        case .cooling, .limitReached, .needsSignIn: true
        case .active, .error, .disabled: false
        }
    }
}

extension RouterBadge {
    var text: Text {
        switch self {
        case .next: Text("1 · Next")
        case .position(let position): Text(verbatim: position.formatted())
        case .shortWindowCap: Text("5-hour cap")
        case .noReading: Text("No reading")
        case .coolingDown: Text("Cooling down")
        case .disabled: Text("Not in rotation")
        case .ended: Text("Ended")
        case .listOrder: Text("List order")
        }
    }

    var isHighlighted: Bool { self == .next }
}

struct RouterBadgeView: View {
    let badge: RouterBadge

    var body: some View {
        badge.text
            .font(.board(.caption).weight(.semibold).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(badge.isHighlighted ? Color.white : Color.secondary)
            .background(badge.isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HeadroomStyle.track), in: .capsule)
            .fixedSize()
            .accessibilityLabel(Text("Router position: \(badge.text)"))
    }
}

struct AccountQuotaCard: View {
    let account: AccountSummary
    var badge: RouterBadge?
    var session: ServerSession?
    var showsProvider = false
    var framed = true
    var showsSources = false
    var opensDetail = false
    @State private var showsStatus = false
    @State private var showsResets = false
    @State private var limitsRequest: LimitsRefreshRequest?

    var body: some View {
        TimelineView(.periodic(from: .now, by: BoardWidth.clockTick)) { context in
            card(now: context.date)
        }
        .sheet(isPresented: $showsResets) {
            ResetsSheet(account: account)
        }
        .modifier(OptionalLimitsSheet(session: session, request: $limitsRequest))
        .modifier(LinkedCardActions(isEnabled: opensDetail, showStatus: { showsStatus = true }, showResets: { showsResets = true }))
    }

    private func card(now: Date) -> some View {
        let status = CardStatus(account: account, now: now)
        let bars = account.cardBars(at: now)
        let idle = account.hasIdleFiveHourWindow(at: now)
        return VStack(alignment: .leading, spacing: 12) {
            header(status: status)
            if bars.isEmpty {
                Text("No quota data reported yet")
                    .font(.board(.subheadline))
                    .foregroundStyle(.secondary)
            }
            ForEach(bars) { bar in
                AccountWindowRow(
                    bar: bar,
                    blocked: status.isBlocked && !isTheLimit(bar, status: status),
                    idle: idle && bar.id == FiveHourWindowState.barID,
                    showsSource: showsSources,
                    now: now
                )
            }
            if !bars.isEmpty || status.backAt != nil {
                Divider()
                footer(status: status, now: now)
            }
        }
        .modifier(CardFrame(framed: framed))
        .opacity(status == .disabled ? 0.7 : 1)
    }

    private func isTheLimit(_ bar: QuotaBar, status: CardStatus) -> Bool {
        bar.id == status.limitBarID
    }

    private func header(status: CardStatus) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if showsProvider {
                ProviderBadge(provider: account.provider, size: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: account.label)
                    .font(.board(.headline))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .modifier(SelectableText(isSelectable: !framed))
                if let plan = account.plan {
                    Text(verbatim: PlanLabel.display(plan))
                        .font(.board(.subheadline))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if let badge {
                RouterBadgeView(badge: badge)
            }
            Button {
                showsStatus = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: status.symbol)
                        .imageScale(.small)
                    Text(status.label)
                    Image(systemName: "chevron.down")
                        .font(.board(.caption2).weight(.bold))
                }
                .font(.board(.caption).weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(status.color)
                .background(status.color.opacity(0.13), in: .capsule)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows why and when the account is back"))
            .popover(isPresented: $showsStatus) {
                StatusPopover(account: account, session: session) {
                    showsStatus = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        limitsRequest = LimitsRefreshRequest(credentialIDs: [account.id])
                    }
                }
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func footer(status: CardStatus, now: Date) -> some View {
        Button {
            showsResets = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: status.isBlocked ? "hourglass" : "clock")
                    .foregroundStyle(status.isBlocked ? .orange : .secondary)
                footerLead(status: status, now: now)
                    .lineLimit(1)
                Text(verbatim: "·").foregroundStyle(.secondary).accessibilityHidden(true)
                Text("all resets")
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.board(.caption).weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.board(.subheadline))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func footerLead(status: CardStatus, now: Date) -> Text {
        if status == .needsSignIn { return Text("Needs a new sign-in") }
        if status.isBlocked {
            guard let back = status.backAt else { return Text("No end time reported") }
            return Text("Back \(ResetClock.text(back))")
        }
        guard let next = account.nextReset(after: now) else { return Text("No reset reported") }
        return Text("Next reset \(ResetClock.text(next))")
    }
}

private struct CardFrame: ViewModifier {
    let framed: Bool

    func body(content: Content) -> some View {
        if framed {
            content.boardCard()
        } else {
            content.padding(.vertical, 6)
        }
    }
}

private struct SelectableText: ViewModifier {
    let isSelectable: Bool

    func body(content: Content) -> some View {
        if isSelectable {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}

private struct LinkedCardActions: ViewModifier {
    let isEnabled: Bool
    let showStatus: () -> Void
    let showResets: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityActions {
                Button("Show status", action: showStatus)
                Button("Show all resets", action: showResets)
            }
        } else {
            content
        }
    }
}

private struct OptionalLimitsSheet: ViewModifier {
    let session: ServerSession?
    @Binding var request: LimitsRefreshRequest?

    func body(content: Content) -> some View {
        if let session {
            content.limitsRefreshSheet(session: session, request: $request)
        } else {
            content
        }
    }
}

struct AccountWindowRow: View {
    let bar: QuotaBar
    let blocked: Bool
    let idle: Bool
    var showsSource = false
    let now: Date

    var body: some View {
        let remaining = bar.remainingPercent(at: now)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                bar.title
                    .font(.board(.subheadline))
                    .lineLimit(1)
                if showsSource, bar.isFromProvider {
                    ProviderSourceMark(sampledAt: bar.sampledAt)
                }
                if idle {
                    Text("idle")
                        .font(.board(.caption2).weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .foregroundStyle(.green)
                        .background(.green.opacity(0.13), in: .capsule)
                }
                Spacer(minLength: 6)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: HeadroomStyle.percentText(remaining))
                        .font(.board(.title3).weight(.semibold).monospacedDigit())
                        .foregroundStyle(numberStyle(remaining))
                    Text("left")
                        .font(.board(.footnote))
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }
            ShareBar(remainingPercent: remaining, fill: blocked ? .blocked : idle ? .idle : .level)
        }
        .accessibilityElement(children: .combine)
    }

    private func numberStyle(_ remaining: Double?) -> Color {
        guard let remaining else { return .secondary }
        if remaining <= 0 { return .red }
        return blocked ? .secondary : .primary
    }
}

struct StatusPopover: View {
    let account: AccountSummary
    let session: ServerSession?
    let checkNow: () -> Void

    static let listedModels = 6

    var body: some View {
        let now = Date.now
        let status = CardStatus(account: account, now: now)
        scrollable {
            VStack(alignment: .leading, spacing: 12) {
                headline(status: status)
                Divider()
                if let why = reason(status) {
                    row("Why") { Text(why) }
                }
                let gains = account.comebackGains(at: now)
                if !gains.isEmpty {
                    row("Comes back") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(gains, id: \.barID) { gain in
                                Text("+\(HeadroomStyle.percentText(gain.percent)) \(String(localized: QuotaWindow(barID: gain.barID).shortLabel))")
                            }
                        }
                    }
                }
                if let resets = account.providerCheck?.resets, resets.everHadResets {
                    row("Manual resets") { manualResets(resets) }
                }
                if let credits = account.creditsBalance {
                    row("Credits") { Text(credits, format: .number.precision(.fractionLength(0...2))) }
                }
                if !account.modelCooldowns.isEmpty {
                    pausedModels
                }
                if let checked = account.providerCheck?.observedAt {
                    Text("Checked with the provider \(ElapsedTime.text(from: checked, to: now)) ago")
                        .font(.board(.footnote))
                        .foregroundStyle(.secondary)
                }
                if canCheck {
                    Button("Check this account now", systemImage: "arrow.triangle.2.circlepath.circle", action: checkNow)
                        .buttonStyle(.bordered)
                        .disabled(session?.refreshingLimits.contains(account.id) == true)
                }
            }
            .padding(18)
        }
        .frame(width: 340)
        .frame(maxHeight: 520)
    }

    @ViewBuilder
    private func scrollable(@ViewBuilder content: () -> some View) -> some View {
        #if os(macOS)
        ViewThatFits(in: .vertical) {
            content()
            ScrollView(content: content)
        }
        #else
        ScrollView(content: content)
        #endif
    }

    private var canCheck: Bool {
        guard let session else { return false }
        return session.supportsLimitsRefresh && ActiveRefreshPolicy.isSupported(account.provider)
    }

    private func headline(status: CardStatus) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.symbol)
                .font(.board(.title2))
                .foregroundStyle(status.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.label)
                    .font(.board(.subheadline).weight(.semibold))
                    .foregroundStyle(status.color)
                Group {
                    switch status {
                    case .cooling(let until?, _), .limitReached(let until?, _): Text("Back \(ResetClock.text(until))")
                    case .cooling, .limitReached: Text("No end time reported")
                    case .active: Text("Usable now")
                    case .needsSignIn: Text("Needs a new sign-in")
                    case .error: Text("Reports an error")
                    case .disabled: Text("Disabled on the server")
                    }
                }
                .font(.board(.title3).weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                if let back = status.backAt, back > .now {
                    Text(back, format: .relative(presentation: .named, unitsStyle: .wide))
                        .font(.board(.subheadline))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reason(_ status: CardStatus) -> LocalizedStringResource? {
        switch status {
        case .limitReached(_, let barID), .cooling(_, let barID?):
            return switch QuotaWindow(barID: barID) {
            case .session5h: "5-hour limit reached"
            case .weekly: "Weekly limit reached"
            case .daily: "Daily limit reached"
            case .monthly: "Monthly limit reached"
            default: "Window limit reached"
            }
        case .cooling:
            let raw = account.cooldownReason?.lowercased() ?? ""
            if raw.contains("quota") { return "Quota used up" }
            if raw.contains("rate") { return "Rate limited by the provider" }
            if raw.contains("auth") || raw.contains("token") { return "Sign-in problem" }
            return "Paused by the proxy after errors"
        case .needsSignIn, .error:
            return account.statusMessage.map { LocalizedStringResource(stringLiteral: $0) }
        case .active, .disabled:
            return nil
        }
    }

    private func manualResets(_ resets: ManualResets) -> Text {
        if let total = resets.total {
            return Text("\(resets.remaining) of \(total) left")
        }
        return Text("\(resets.remaining) left")
    }

    private var pausedModels: some View {
        let cooldowns = account.modelCooldowns
        let latest = cooldowns.contains { $0.until == nil } ? nil : cooldowns.compactMap(\.until).max()
        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if let latest {
                    Text("\(Text("\(cooldowns.count) models paused")) until \(ResetClock.text(latest))")
                } else {
                    Text("\(cooldowns.count) models paused")
                }
            }
            .font(.board(.subheadline).weight(.semibold))
            FlowLayout(spacing: 6) {
                ForEach(cooldowns.prefix(Self.listedModels), id: \.self) { cooldown in
                    Text(verbatim: cooldown.model)
                        .font(.board(.caption).monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(HeadroomStyle.track, in: .rect(cornerRadius: 8))
                }
                if cooldowns.count > Self.listedModels {
                    Text("and \(cooldowns.count - Self.listedModels) more")
                        .font(.board(.caption))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func row(_ title: LocalizedStringResource, @ViewBuilder value: () -> some View) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                value()
                    .multilineTextAlignment(.trailing)
                    .fontWeight(.medium)
            }
            .font(.board(.subheadline))
            Divider()
        }
    }
}

struct ResetsSheet: View {
    let account: AccountSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: BoardWidth.clockTick)) { context in
                list(now: context.date)
            }
            .navigationTitle(Text("Resets"))
            .navigationSubtitle(Text(verbatim: [account.label, account.plan.map(PlanLabel.display)].compactMap(\.self).joined(separator: " · ")))
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 420)
        #endif
    }

    private func list(now: Date) -> some View {
        List {
            Section {
                let resets = account.resets(at: now)
                if resets.isEmpty {
                    Text("No quota data reported yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(resets) { reset in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            title(reset)
                            when(reset, now: now)
                                .font(.board(.subheadline))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            if let resetsAt = reset.resetsAt, resetsAt > now {
                                ResetClock.text(resetsAt)
                                    .font(.board(.headline).monospacedDigit())
                            }
                            if let gain = reset.gainAtReset, gain > 0 {
                                Text("+\(HeadroomStyle.percentText(gain)) back")
                                    .font(.board(.subheadline).weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !account.modelCooldowns.isEmpty {
                Section {
                    ForEach(account.modelCooldowns, id: \.self) { cooldown in
                        LabeledContent {
                            pausedUntil(cooldown, now: now)
                                .font(.board(.subheadline).monospacedDigit())
                        } label: {
                            Text(verbatim: cooldown.model)
                                .font(.board(.subheadline).monospaced())
                        }
                    }
                } header: {
                    Text("Paused models")
                }
            }
            if let resets = account.providerCheck?.resets, resets.everHadResets {
                Section {
                    LabeledContent {
                        Text(verbatim: resets.total.map { "\(resets.remaining) / \($0)" } ?? "\(resets.remaining)")
                            .font(.board(.headline).monospacedDigit())
                    } label: {
                        Text("Manual resets")
                        if let expires = resets.expiresAt {
                            Text("expire \(ResetClock.text(expires))")
                        }
                    }
                }
            }
            if let checked = account.providerCheck?.observedAt {
                Section {
                } footer: {
                    Text("Checked with the provider \(ElapsedTime.text(from: checked, to: now)) ago")
                }
            }
        }
    }

    private func pausedUntil(_ cooldown: ModelCooldown, now: Date) -> Text {
        guard let until = cooldown.until else { return Text("No end time reported") }
        return until > now ? Text("Back \(ResetClock.text(until))") : Text("Ended")
    }

    private func title(_ reset: WindowReset) -> Text {
        reset.label.map { Text(verbatim: $0) } ?? Text(QuotaWindow(barID: reset.barID).label)
    }

    private func when(_ reset: WindowReset, now: Date) -> Text {
        if reset.startsOnFirstUse { return Text("Starts on first use") }
        guard let resetsAt = reset.resetsAt else { return Text("No reset time reported") }
        guard resetsAt > now else { return Text("Reset at \(ResetClock.text(resetsAt)); waiting for a new sample") }
        let left = HeadroomStyle.percentText(reset.remainingPercent)
        return Text("\(left) left now · in \(Text(resetsAt, style: .relative))")
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
