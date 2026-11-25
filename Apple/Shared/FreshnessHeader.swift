import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

extension Freshness {
    @MainActor
    init(session: ServerSession, scope: RefreshScope, now: Date) {
        let key = scope.freshnessKey(authMode: session.profile.authMode)
        self.init(
            failed: session.failure(for: key) != nil || session.pauseReason != nil,
            loaded: session.hasLoaded(key),
            lastRefresh: session.lastRefresh(for: scope),
            savedAt: key == session.headroomScope ? session.quotaOverview(at: now).savedAt : nil
        )
    }

    var dotColor: Color {
        switch self {
        case .fresh: .green
        case .notRefreshed: .secondary
        case .saved: .orange
        case .notReached: .red
        }
    }
}

struct FreshnessHeader: View {
    let session: ServerSession
    let scope: RefreshScope
    var credentialIDs: [String]?
    @State private var apiProgress: Double?
    @State private var apiResult: FreshnessActivity.Result?
    @State private var showingReport: ProviderRefreshReport?
    @State private var isOnScreen = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let activity = activity(at: context.date)
            let canReload = !session.isRefreshing && session.refreshingLimits.isEmpty && activity.progress == nil
            let provider = providerAction(at: context.date, busy: activity.progress != nil || session.isRefreshing)
            FreshnessRow(
                freshness: Freshness(session: session, scope: scope, now: context.date),
                now: context.date,
                reload: .init(action: reload, enabled: canReload),
                provider: provider,
                activity: activity,
                showReport: { showingReport = $0 }
            )
            #if os(macOS)
            .focusedSceneValue(\.paneRefresh, isOnScreen ? PaneRefresh(reload: .init(action: reload, enabled: canReload), provider: provider) : nil)
            #endif
        }
        .sheet(item: $showingReport) { report in
            ProviderRefreshResults(session: session, report: report)
        }
        #if os(macOS)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        #endif
    }

    private func providerAction(at now: Date, busy: Bool) -> FreshnessAction {
        let plan = session.surfaceLimitsRefreshPlan(for: credentialIDs, now: now)
        let help: LocalizedStringResource?
        if !session.supportsLimitsRefresh {
            help = "Provider refresh requires management access."
        } else if !session.accountsLoaded {
            help = "Reload accounts from API first."
        } else if plan.isEmpty, let next = plan.waiting.map(\.until).min() {
            help = "Available in \(Int(max(1, ceil(next.timeIntervalSince(now))))) s"
        } else if plan.isEmpty {
            help = "No account can be checked right now."
        } else {
            help = nil
        }
        return FreshnessAction(action: refreshProvider, enabled: !busy && session.refreshingLimits.isEmpty && help == nil, help: help)
    }

    private func activity(at now: Date) -> FreshnessActivity {
        if let apiProgress { return .init(progress: .api(apiProgress)) }
        if let progress = session.providerRefreshProgress { return .init(progress: .provider(progress)) }
        let provider = session.providerRefreshReport.map(FreshnessActivity.Result.provider)
        let result = [apiResult, provider].compactMap { $0 }.max { $0.finishedAt < $1.finishedAt }
        return .init(result: result.flatMap { now.timeIntervalSince($0.finishedAt) < 5 ? $0 : nil })
    }

    private func reload() {
        guard apiProgress == nil, session.providerRefreshProgress == nil, !session.isRefreshing else { return }
        apiResult = nil
        apiProgress = 0
        Task {
            let success = await session.reloadFromAPI(scope) { apiProgress = $0 }
            apiResult = .api(success: success, finishedAt: .now)
            apiProgress = nil
        }
    }

    private func refreshProvider() {
        guard apiProgress == nil, providerAction(at: .now, busy: session.isRefreshing).enabled else { return }
        Task { await session.refreshProviderFromSurface(credentialIDs) }
    }
}

struct FreshnessAction {
    let action: () -> Void
    let enabled: Bool
    var help: LocalizedStringResource?
}

struct FreshnessActivity {
    enum Progress {
        case api(Double)
        case provider(ProviderRefreshProgress)

        var fraction: Double {
            switch self {
            case .api(let fraction): fraction
            case .provider(let progress): Double(progress.completed) / Double(max(1, progress.total))
            }
        }

        var checksProvider: Bool {
            if case .provider = self { return true }
            return false
        }
    }

    enum Result {
        case api(success: Bool, finishedAt: Date)
        case provider(ProviderRefreshReport)

        var finishedAt: Date {
            switch self {
            case .api(_, let date): date
            case .provider(let report): report.finishedAt
            }
        }
    }

    var progress: Progress?
    var result: Result?
}

struct FreshnessRow: View {
    let freshness: Freshness
    let now: Date
    let reload: FreshnessAction
    let provider: FreshnessAction
    var activity = FreshnessActivity()
    var showReport: (ProviderRefreshReport) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    statusLabel.fixedSize()
                    Spacer(minLength: 0)
                    actions.fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    statusLabel
                    ViewThatFits(in: .horizontal) {
                        actions.fixedSize()
                        VStack(alignment: .leading, spacing: 6) {
                            reloadButton
                            providerButton
                        }
                    }
                }
            }
            activityLine
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(FreshnessSurface())
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var statusLabel: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(freshness.dotColor)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            status.font(.board(.subheadline))
        }
    }

    @ViewBuilder
    private var status: some View {
        switch freshness {
        case .fresh(let date):
            Text("Updated \(Text(date, format: .dateTime.hour().minute()).fontWeight(.semibold)) · \(ElapsedTime.text(from: date, to: now)) ago")
        case .notRefreshed:
            Text("Not refreshed yet")
        case .saved(let date):
            Text("Saved data from \(ResetClock.text(date).fontWeight(.semibold))")
        case .notReached(let date?):
            Text("Server not reached · data from \(ResetClock.text(date))")
        case .notReached(nil):
            Text("Server not reached")
        }
    }

    private var actions: some View {
        HStack(alignment: .top, spacing: 6) {
            reloadButton
            providerButton
        }
    }

    private var reloadButton: some View {
        button("Reload from API", symbol: "arrow.clockwise", action: reload, busy: activity.progress?.checksProvider == false)
    }

    private var providerButton: some View {
        VStack(alignment: .leading, spacing: 2) {
            button("Refresh from provider", symbol: "antenna.radiowaves.left.and.right", action: provider, busy: activity.progress?.checksProvider == true)
            if let help = provider.help, activity.progress == nil {
                Text(help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func button(_ title: LocalizedStringResource, symbol: String, action: FreshnessAction, busy: Bool) -> some View {
        Button(action: action.action) {
            Label {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                }
            }
            .labelStyle(.titleAndIcon)
            .font(.board(.subheadline).weight(.semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(!action.enabled || busy)
        .help(Text(action.help ?? title))
    }

    @ViewBuilder
    private var activityLine: some View {
        if let progress = activity.progress {
            ProgressView(value: progress.fraction) {
                switch progress {
                case .api:
                    Text("Loading…")
                case .provider(let progress):
                    if progress.total == 0 {
                        Text("Refreshing from provider…")
                    } else if progress.total == 1 {
                        Text("Checking account…")
                    } else {
                        Text("Checking \(progress.completed) of \(progress.total) accounts…")
                    }
                }
            }
            .progressViewStyle(.linear)
            .font(.board(.footnote).monospacedDigit())
            .controlSize(.small)
            .foregroundStyle(.secondary)
        } else if let result = activity.result {
            switch result {
            case .api(let success, _):
                Text(success ? "Reloaded" : "Reload failed")
                    .font(.board(.footnote))
                    .foregroundStyle(.secondary)
            case .provider(let report):
                Button {
                    showReport(report)
                } label: {
                    Label {
                        if report.checked == 1 {
                            Text("Checked 1 account · \(report.failed) failed")
                        } else {
                            Text("Checked \(report.checked) accounts · \(report.failed) failed")
                        }
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.board(.footnote).monospacedDigit())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows the result for each account"))
            }
        }
    }
}

private struct FreshnessSurface: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .background(BoardStyle.cardBackground, in: .rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
        #else
        content.glassEffect(.regular, in: .rect(cornerRadius: 20))
        #endif
    }
}

extension View {
    func freshnessHeader(session: ServerSession, scope: RefreshScope, credentialIDs: [String]? = nil) -> some View {
        #if os(macOS)
        safeAreaInset(edge: .top, spacing: 0) {
            FreshnessHeader(session: session, scope: scope, credentialIDs: credentialIDs)
                .padding(.top, 8)
                .background(BoardStyle.pageBackground)
        }
        #else
        safeAreaBar(edge: .top) {
            FreshnessHeader(session: session, scope: scope, credentialIDs: credentialIDs)
        }
        #endif
    }
}

#if os(macOS)
struct PaneRefresh {
    let reload: FreshnessAction
    let provider: FreshnessAction
}

extension FocusedValues {
    @Entry var paneRefresh: PaneRefresh?
}
#endif
