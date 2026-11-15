import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct LimitsRefreshRequest: Identifiable {
    let id = UUID()
    let credentialIDs: [String]?
}

extension View {
    func limitsRefreshSheet(session: ServerSession, request: Binding<LimitsRefreshRequest?>) -> some View {
        sheet(item: request) { pending in
            LimitsRefreshSheet(session: session, credentialIDs: pending.credentialIDs)
        }
    }
}

struct RefreshLimitsButton: View {
    let session: ServerSession
    var credentialIDs: [String]?
    @State private var request: LimitsRefreshRequest?

    var body: some View {
        Button {
            request = LimitsRefreshRequest(credentialIDs: credentialIDs)
        } label: {
            Label("Refresh limits", systemImage: "arrow.triangle.2.circlepath.circle")
        }
        .disabled(!session.supportsLimitsRefresh || !session.refreshingLimits.isEmpty)
        .help(Text("Ask the providers for fresh limits through the server"))
        .limitsRefreshSheet(session: session, request: $request)
    }
}

struct LimitsRefreshSheet: View {
    let session: ServerSession
    let credentialIDs: [String]?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let plan = session.limitsRefreshPlan(for: credentialIDs)
        let needsAccounts = !session.accountsLoaded || session.isAutomaticRefreshPaused
        NavigationStack {
            Form {
                Section {
                    Text("Proxy Gauge asks your server to contact each provider with the account's own sign-in, the same requests the management panel sends for Refresh quota. The server does not keep the answers; this device does.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if needsAccounts {
                    Section {
                        AccountsNotLoadedRow(session: session)
                    }
                } else if plan.isEmpty {
                    Section {
                        Text("No account can be checked right now.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(plan.groups) { group in
                            ProviderGroupRow(group: group)
                        }
                    } header: {
                        Text("Will be contacted")
                    } footer: {
                        Text("At most \(plan.maximumRequests) requests, sent one at a time.")
                    }
                }
                if plan.mayRunPaidCompletion {
                    Section {
                        WarningRow(symbol: "dollarsign.circle", tint: .orange) {
                            Text("xAI: when both billing endpoints answer but report no usage, the refresh falls back to the panel's paid-key check, which sends one chat completion with max_tokens 1 to api.x.ai. On a paid key this can cost a token. A billing error never leads to this check.")
                        }
                    }
                }
                if plan.usesUnofficialGoogleEndpoints {
                    Section {
                        WarningRow(symbol: "exclamationmark.shield", tint: .orange) {
                            Text("Antigravity uses unofficial Google endpoints, and Google's terms restrict access by third-party tools. Refresh these accounts only if you accept that risk.")
                        }
                    }
                }
                if !plan.waiting.isEmpty {
                    Section("Not refreshed now") {
                        ForEach(plan.waiting) { waiting in
                            LabeledAccountRow(provider: waiting.provider, label: waiting.label) {
                                WaitText(until: waiting.until, because: waiting.because)
                            }
                        }
                    }
                }
                if !plan.skipped.isEmpty {
                    Section("Skipped") {
                        ForEach(plan.skipped) { skipped in
                            LabeledAccountRow(provider: skipped.provider, label: skipped.label) {
                                Text(skipped.reason.explanation)
                            }
                        }
                    }
                }
                Section {
                    Text("Refreshing limits never redeems manual resets, never spends reset credits and never retries through another route. Providers that answer with a rate limit are left alone until they allow it again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("Refresh limits"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Refresh limits") {
                        let ids = credentialIDs
                        Task { await session.refreshLimits(ids, trigger: .manual, origin: .visibleApp) }
                        dismiss()
                    }
                    .disabled(plan.isEmpty || needsAccounts)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }
}

private struct AccountsNotLoadedRow: View {
    let session: ServerSession

    var body: some View {
        if session.isLoading(.accounts) {
            Label {
                Text("Loading the accounts from the server…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                reason
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Load accounts", systemImage: "arrow.clockwise") {
                    Task { await session.refresh(.accounts, trigger: .manual) }
                }
            }
        }
    }

    @ViewBuilder
    private var reason: some View {
        if let pause = session.pauseReason {
            Text(pause.pausedNote)
        } else if let failure = session.failure(for: .accounts) {
            Text("The accounts could not be loaded: \(Text(failure.userMessage))")
        } else {
            Text("Load the accounts first. Nothing is sent to the server until you do.")
        }
    }
}

private struct ProviderGroupRow: View {
    let group: LimitsRefreshPlan.ProviderGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProviderBadge(provider: group.provider, size: 22)
                Text(ProviderCatalog.displayName(group.provider))
                    .font(.body.weight(.medium))
                Spacer()
                Text("Accounts: \(group.accounts.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(group.requests.map { String(localized: $0.label) }.formatted(.list(type: .and))) · at most \(group.maximumRequestsPerAccount) per account")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: group.accounts.joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

private struct LabeledAccountRow<Detail: View>: View {
    let provider: String
    let label: String
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProviderBadge(provider: provider, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: label)
                    .font(.callout)
                detail()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct WarningRow<Message: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder let message: () -> Message

    var body: some View {
        Label {
            message()
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
    }
}

struct WaitText: View {
    let until: Date
    let because: ActiveRefreshWait

    var body: some View {
        switch because {
        case .rateLimited: Text("Rate limited by provider, next try at \(ResetClock.text(until))")
        case .recentlyChecked: Text("Checked recently, next refresh allowed at \(ResetClock.text(until))")
        case .proxyRefused: Text("The proxy refused provider checks, next automatic try at \(ResetClock.text(until))")
        }
    }
}

struct ProxyRefusalText: View {
    let notice: ProxyRefusalNotice

    var body: some View {
        switch notice {
        case .nextAutomaticTry(let until): WaitText(until: until, because: .proxyRefused)
        case .automaticChecksPaused(let until): Text("The proxy refused provider checks, automatic checks are paused until \(ResetClock.text(until))")
        }
    }
}

extension ActiveRequestKind {
    var label: LocalizedStringResource {
        switch self {
        case .usage: "usage"
        case .profile: "profile"
        case .resetGrants: "reset grants"
        case .subscription: "subscription"
        case .resetCredits: "reset credits"
        case .quotaSummary: "quota summary"
        case .plan: "plan"
        case .userStatus: "account status"
        case .billing: "billing"
        case .paidKeyCheck: "paid-key check"
        }
    }
}

extension ProxyAccountRefusal {
    var explanation: LocalizedStringResource {
        switch self {
        case .signInRefreshFailed: "The proxy could not refresh this account's sign-in."
        case .accountNotFound: "The proxy no longer has this account. Refresh the account list."
        case .signInMissing: "The proxy has no sign-in token for this account."
        case .requestRejected: "The proxy rejected the check for this account."
        }
    }
}

extension ActiveRefreshSkip {
    var explanation: LocalizedStringResource {
        switch self {
        case .unsupported: "Not supported: the management panel has no quota reader for this provider."
        case .disabled: "Disabled on the server."
        case .missingAuthIndex: "The server did not report an auth index for this account."
        case .missingProject: "The server did not report a Google Cloud project for this account."
        case .notVisible, .excludedFromAutomatic, .automaticSuspended, .rejectedByProvider: "Checked only when you refresh limits by hand."
        }
    }
}

struct PlanChip: View {
    let plan: String

    var body: some View {
        Text(verbatim: PlanLabel.display(plan))
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.14), in: .capsule)
            .foregroundStyle(Color.accentColor)
    }
}

struct ProviderCheckNotes: View {
    let account: AccountSummary
    var showsCheckTime = true

    var body: some View {
        let now = Date.now
        if let state = account.providerCheckState {
            if state.isRateLimited(at: now), let until = state.rateLimitedUntil {
                Label {
                    Text("Rate limited by provider, next try at \(ResetClock.text(until))")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "tortoise")
                }
                .foregroundStyle(.orange)
            }
            if state.automaticSuspended {
                Text("Automatic limit refresh is paused for this account after repeated rate limits.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = state.rejectedStatus {
                Text("The provider rejected this account (HTTP \(status)). Automatic limit refresh stays off for it until you refresh it by hand.")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch state.lastFailureNote {
            case .upstream(let status):
                Text("The last provider check failed (HTTP \(status)).")
                    .foregroundStyle(.secondary)
            case .unreadable:
                Text("The last provider check returned no readable limits.")
                    .foregroundStyle(.secondary)
            case .refusedByProxy(let refusal):
                Text(refusal.explanation)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
        }
        if let check = account.providerCheck {
            if let resets = check.resets, resets.everHadResets {
                ResetsLine(resets: resets)
            }
            if let extra = check.extraUsage, extra.isEnabled != false, let limit = extra.limit {
                Text("Extra usage: \(Money.text(extra.used ?? 0, currency: extra.currency)) of \(Money.text(limit, currency: extra.currency))")
                    .foregroundStyle(.secondary)
            }
            if let credits = check.credits, credits.unlimited {
                Text("Credits: unlimited")
                    .foregroundStyle(.secondary)
            } else if let credits = check.credits, let balance = credits.balance, credits.currency != nil {
                Text("Credits: \(Money.text(balance, currency: credits.currency))")
                    .foregroundStyle(.secondary)
            }
            if check.note == .paidKeyAnswered {
                Text("The paid API key answered a 1-token check.")
                    .foregroundStyle(.secondary)
            }
            if check.note == .limitReached {
                Label {
                    Text("The provider reported this account as blocked although no window was full.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised")
                }
                .foregroundStyle(.orange)
            }
            if showsCheckTime {
                ElapsedText(since: check.observedAt) { Text("Checked with the provider \($0) ago") }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ResetsLine: View {
    let resets: ManualResets

    var body: some View {
        Group {
            if let expiresAt = resets.expiresAt, resets.remaining > 0 {
                Text("Manual resets left: \(countText) · expires \(ResetClock.text(expiresAt))")
            } else {
                Text("Manual resets left: \(countText)")
            }
        }
        .foregroundStyle(.secondary)
    }

    private var countText: String {
        if let total = resets.total, total > 0 { return "\(resets.remaining)/\(total)" }
        return String(resets.remaining)
    }
}

enum Money {
    static func text(_ amount: Double, currency: String?) -> String {
        amount.formatted(.currency(code: currency ?? "USD").precision(.fractionLength(0...2)))
    }
}

struct ProviderRefreshStatus: View {
    let session: ServerSession

    var body: some View {
        if !session.refreshingLimits.isEmpty {
            Label {
                Text("Checking limits with the providers…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        if let notice = session.proxyRefusalNotice(at: .now) {
            Label {
                ProxyRefusalText(notice: notice)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
        }
        if let error = session.limitsRefreshError {
            Label {
                Text("Refresh limits failed: \(Text(error.userMessage))")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
        }
    }
}

struct ProviderRefreshLoopID: Hashable {
    static let tick: Duration = .seconds(60)

    var session: UUID
    var enabled: Bool
    var interval: TimeInterval
    var isVisible: Bool
}
