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

    var showsMessageOnCard: Bool {
        self == .needsSignIn || self == .error
    }
}

extension RouterBadge {
    var text: Text {
        switch self {
        case .ranked(let position, let tier):
            let place = position == 1 ? Text("1 Next") : Text(verbatim: position.formatted())
            return switch tier {
            case .room: place
            case .capped: place + Text(verbatim: " · ") + Text("5-hour cap")
            case .limited: place + Text(verbatim: " · ") + Text("weekly limit")
            }
        case .noReading: return Text("No reading")
        case .coolingDown: return Text("Cooling down")
        case .disabled: return Text("Not in rotation")
        case .ended: return Text("Ended")
        case .listOrder: return Text("List order")
        }
    }

    var color: Color {
        switch self {
        case .ranked(_, .capped), .ranked(_, .limited), .coolingDown: .orange
        case .ranked(1, _): .green
        case .ranked, .noReading, .disabled, .ended, .listOrder: .secondary
        }
    }
}

struct CardPill: View {
    let badge: RouterBadge?
    let status: CardStatus

    var body: some View {
        if let badge, badge != .listOrder {
            capsule(badge.text, color: badge.color)
                .accessibilityLabel(Text("Router position: \(badge.text)"))
        } else if status == .active {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
                .padding(6)
                .background(BoardStyle.cardBackground, in: .circle)
                .overlay { Circle().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
                .accessibilityLabel(Text(status.label))
        } else {
            capsule(Text(status.label), color: status.color)
        }
    }

    private func capsule(_ text: Text, color: Color) -> some View {
        text
            .font(.board(.caption).weight(.semibold).monospacedDigit())
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: .capsule)
            .background(BoardStyle.cardBackground, in: .capsule)
            .overlay { Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.75) }
            .fixedSize()
    }
}

struct AccountQuotaCard: View {
    let account: AccountSummary
    var badge: RouterBadge?
    var session: ServerSession?
    var slots: [WindowSlot]?
    var framed = true
    var showsSources = false
    var opensDetail = false
    @State private var showsStatus = false
    @State private var showsResets = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: BoardWidth.clockTick)) { context in
            card(now: context.date)
        }
        .sheet(isPresented: $showsResets) {
            ResetsSheet(account: account)
        }
        .modifier(LinkedCardActions(isEnabled: opensDetail, showStatus: { showsStatus = true }, showResets: { showsResets = true }))
    }

    private func card(now: Date) -> some View {
        let status = CardStatus(account: account, now: now)
        let slots = slots ?? QuotaSlots.slots(provider: account.provider, accounts: [account])
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                nameLine(status: status)
                facts(now: now)
            }
            if slots.isEmpty {
                Text("No quota data reported yet")
                    .font(.board(.footnote))
                    .foregroundStyle(.secondary)
            }
            ForEach(QuotaSlots.readings(account, slots: slots, at: now)) { reading in
                SlotReadingRow(reading: reading, showsSource: showsSources, now: now)
            }
            if let problem = problem(status) {
                Text(verbatim: problem)
                    .font(.board(.footnote))
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.1), in: .rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.red.opacity(0.35), lineWidth: 0.75) }
            }
            footer(now: now)
        }
        .padding(.top, framed ? 4 : 0)
        .modifier(CardFrame(framed: framed))
        .overlay(alignment: .topTrailing) {
            if framed {
                pill(status: status)
                    .alignmentGuide(.top) { $0[VerticalAlignment.center] }
                    .padding(.trailing, 12)
            }
        }
        .opacity(status == .disabled ? 0.7 : 1)
    }

    private func nameLine(status: CardStatus) -> some View {
        HStack(spacing: 6) {
            ProviderBadge(provider: account.provider, size: 18)
            Text(verbatim: account.label)
                .font(.board(.subheadline).weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .modifier(SelectableText(isSelectable: !framed))
            if !framed {
                Spacer(minLength: 6)
                pill(status: status)
            }
        }
    }

    private func pill(status: CardStatus) -> some View {
        Button {
            showsStatus = true
        } label: {
            CardPill(badge: badge, status: status)
                .padding(12)
                .contentShape(.rect)
                .padding(-12)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Shows why and when the account is back"))
        .popover(isPresented: $showsStatus) {
            StatusPopover(account: account, session: session, checkNow: {
                showsStatus = false
                Task { await session?.refreshProviderFromSurface([account.id]) }
            }, showResets: {
                showsStatus = false
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    showsResets = true
                }
            })
            .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private func facts(now: Date) -> some View {
        let resets = account.cardResets(at: now)
        if account.cardPlan == nil, resets == nil, paidUntil == nil {
            Text(verbatim: " ")
                .font(.board(.footnote))
                .accessibilityHidden(true)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { factItems(short: false, resets: resets) }
                HStack(spacing: 10) { factItems(short: true, resets: resets) }
                FlowLayout(spacing: 10) { factItems(short: true, resets: resets) }
            }
            .font(.board(.footnote))
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func factItems(short: Bool, resets: ManualResets?) -> some View {
        if let plan = account.cardPlan {
            HStack(spacing: 4) {
                if !short {
                    Text("Plan").foregroundStyle(.secondary)
                }
                Text(verbatim: PlanLabel.display(plan))
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .background(PlanTint.color(account, plan: plan).opacity(0.22), in: .capsule)
            }
            .fixedSize()
        }
        if let resets {
            HStack(spacing: 4) {
                (short ? Text("Resets") : Text("Resets remaining")).foregroundStyle(.secondary)
                Text(verbatim: resets.remaining.formatted())
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .fixedSize()
        }
        if let paidUntil {
            HStack(spacing: 4) {
                Text("Paid until").foregroundStyle(.secondary)
                Text(verbatim: PanelDate.day(paidUntil))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .fixedSize()
        }
    }

    private var paidUntil: Date? {
        account.provider.lowercased() == "codex" ? account.cardPaidUntil : nil
    }

    private func problem(_ status: CardStatus) -> String? {
        switch status {
        case .needsSignIn: account.statusMessage ?? String(localized: "Needs a new sign-in")
        case .error: account.statusMessage ?? String(localized: "Reports an error")
        case .active, .cooling, .limitReached: account.providerCheckFailure.map(\.cardText)
        case .disabled: nil
        }
    }

    @ViewBuilder
    private func footer(now: Date) -> some View {
        let extra = account.cardExtraUsage?.isEnabled
        if account.endsAt != nil || extra != nil {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                if let endsAt = account.endsAt {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Ends")
                            .textCase(.uppercase)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text(verbatim: PanelDate.day(endsAt))
                            .monospacedDigit()
                        Text(verbatim: PanelDate.relative(endsAt, now: now))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                }
                if let extra {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) {
                            Text("Extra usage")
                            Spacer(minLength: 4)
                            Text(extra ? "Enabled" : "Disabled")
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Extra usage")
                            Text(extra ? "Enabled" : "Disabled")
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.board(.footnote))
        }
    }
}

extension ActiveRefreshFailure {
    var cardText: String {
        switch self {
        case .rateLimited: String(localized: "Failed to load quota: the provider is rate limiting checks.")
        case .rejected(let status): String(localized: "Failed to load quota: the provider rejected this account (HTTP \(status)).")
        case .upstream(let status): String(localized: "Failed to load quota: HTTP \(status).")
        case .unreadable: String(localized: "Failed to load quota: no readable limits in the answer.")
        case .requiresPaidKeyConsent: String(localized: "No billing data was reported. A paid-key check needs approval.")
        case .management: String(localized: "Failed to load quota: the server could not run the check.")
        case .refusedByProxy(let refusal): String(localized: refusal.explanation)
        }
    }
}

enum PlanTint {
    static func color(_ account: AccountSummary, plan rawPlan: String) -> Color {
        let plan = rawPlan.lowercased()
        let weight = PlanWeight.multiplier(provider: account.provider, plan: rawPlan)
        if weight == 20 || plan.contains("500") || plan.contains("heavy") || plan.contains("ultra") { return .orange }
        if weight == 5 || plan.hasPrefix("max") || plan.contains("200") || plan.contains("100") || plan.contains("supergrok") { return .yellow }
        return .gray
    }
}

private struct CardFrame: ViewModifier {
    let framed: Bool

    func body(content: Content) -> some View {
        if framed {
            content.boardCard(inset: PanelStyle.cardInset)
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

struct StatusPopover: View {
    let account: AccountSummary
    let session: ServerSession?
    let checkNow: () -> Void
    var showResets: (() -> Void)?

    static let listedModels = 6

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { content(at: $0.date) }
    }

    private func content(at now: Date) -> some View {
        let status = CardStatus(account: account, now: now)
        return scrollable {
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
                if let check = account.providerCheck { providerFacts(check, now: now) }
                if let credits = account.creditsBalance {
                    row("Credits") { Text(credits, format: .number.precision(.fractionLength(0...2))) }
                }
                if !account.modelCooldowns.isEmpty {
                    pausedModels
                }
                if let showResets {
                    Button("Show all resets", systemImage: "clock", action: showResets)
                        .buttonStyle(.bordered)
                }
                if canCheck, let session {
                    let plan = session.surfaceLimitsRefreshPlan(for: [account.id], now: now)
                    VStack(alignment: .leading, spacing: 2) {
                        Button("Refresh from provider", systemImage: "antenna.radiowaves.left.and.right", action: checkNow)
                            .buttonStyle(.bordered)
                            .disabled(!session.refreshingLimits.isEmpty || session.providerRefreshProgress != nil || plan.isEmpty)
                        if plan.isEmpty, let until = plan.waiting.map(\.until).min() {
                            Text("Available in \(Int(max(1, ceil(until.timeIntervalSince(now))))) s")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
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

    private struct ProviderFact {
        let field: ActiveQuotaField
        let title: LocalizedStringResource
        let value: Text
    }

    private func facts(_ check: ProviderCheck, now: Date) -> [ProviderFact] {
        var facts: [ProviderFact] = []
        if let resets = check.resets?.usable(at: now) {
            facts.append(ProviderFact(field: .resets, title: "Manual resets", value: manualResets(resets)))
        }
        if !account.isCurrentProviderFact(.plan), let plan = check.plan {
            facts.append(ProviderFact(field: .plan, title: "Plan", value: Text(verbatim: PlanLabel.display(plan))))
        }
        if !account.isCurrentProviderFact(.planActiveUntil), let date = check.planActiveUntil {
            facts.append(ProviderFact(field: .planActiveUntil, title: "Paid until", value: Text(verbatim: PanelDate.day(date))))
        }
        if !account.isCurrentProviderFact(.extraUsage), let enabled = check.extraUsage?.isEnabled {
            facts.append(ProviderFact(field: .extraUsage, title: "Extra usage", value: Text(enabled ? "Enabled" : "Disabled")))
        }
        return facts
    }

    private func providerFacts(_ check: ProviderCheck, now: Date) -> some View {
        let latestAge = ElapsedTime.text(from: check.observedAt, to: now)
        let latestCheckSpan: TimeInterval = 10
        let timedFacts = facts(check, now: now).map { ($0, check.sampledAt(for: $0.field)) }.sorted { $0.1 > $1.1 }
        var orderedAges = [latestAge]
        var byAge: [String: [ProviderFact]] = [:]
        for (fact, sampledAt) in timedFacts {
            let age = check.observedAt.timeIntervalSince(sampledAt) <= latestCheckSpan ? latestAge : ElapsedTime.text(from: sampledAt, to: now)
            if !orderedAges.contains(age) { orderedAges.append(age) }
            byAge[age, default: []].append(fact)
        }
        return ForEach(orderedAges, id: \.self) { age in
            VStack(alignment: .leading, spacing: 4) {
                ForEach(byAge[age, default: []], id: \.field) { fact in
                    row(fact.title) { fact.value }
                }
                Text("Checked with the provider \(age) ago")
                    .font(.board(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func manualResets(_ resets: ManualResets) -> Text {
        guard resets.remaining > 0 else { return Text("None") }
        if !resets.hasUsabilityDetails, let total = resets.total, total > 0 {
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
            if let resets = account.providerCheck?.resets?.usable(at: now), resets.remaining > 0 {
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
