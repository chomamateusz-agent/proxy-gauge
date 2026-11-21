import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

extension Freshness {
    @MainActor
    init(session: ServerSession, scope: RefreshScope, now: Date) {
        self.init(
            failed: session.failure(for: scope) != nil || session.pauseReason != nil,
            loaded: session.hasLoaded(scope),
            lastRefresh: session.lastRefresh(for: scope),
            savedAt: scope == session.headroomScope ? session.quotaOverview(at: now).savedAt : nil
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

    var buttonTitle: LocalizedStringResource {
        switch self {
        case .fresh, .notRefreshed: "Refresh"
        case .saved: "Retry"
        case .notReached: "Try again"
        }
    }
}

struct FreshnessHeader: View {
    let session: ServerSession
    let scope: RefreshScope
    var credentialIDs: [String]?
    var reload: (@MainActor () async -> Void)?
    @State private var limitsRequest: LimitsRefreshRequest?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            FreshnessRow(
                freshness: Freshness(session: session, scope: scope, now: context.date),
                isRefreshing: session.isRefreshing,
                now: context.date,
                refresh: { Task { await runReload() } },
                checkLimits: session.supportsLimitsRefresh ? { limitsRequest = LimitsRefreshRequest(credentialIDs: credentialIDs) } : nil,
                checkingLimits: !session.refreshingLimits.isEmpty
            )
        }
        .limitsRefreshSheet(session: session, request: $limitsRequest)
    }

    private func runReload() async {
        if let reload {
            await reload()
        } else {
            await session.refresh(scope, trigger: .manual)
        }
    }
}

struct FreshnessRow: View {
    let freshness: Freshness
    let isRefreshing: Bool
    let now: Date
    let refresh: () -> Void
    var checkLimits: (() -> Void)?
    var checkingLimits = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(freshness.dotColor)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            status
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            refreshButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var status: some View {
        switch freshness {
        case .fresh(let date):
            Text("Updated \(Text(date, format: .dateTime.hour().minute()).fontWeight(.semibold)) · \(ElapsedTime.text(from: date, to: now)) ago")
        case .notRefreshed:
            isRefreshing ? Text("Refreshing…") : Text("Not refreshed yet")
        case .saved(let date):
            Text("Saved data from \(ResetClock.text(date).fontWeight(.semibold))")
        case .notReached(let date?):
            Text("Server not reached · data from \(ResetClock.text(date))")
        case .notReached(nil):
            Text("Server not reached")
        }
    }

    private var refreshButton: some View {
        Group {
            if let checkLimits {
                Menu {
                    Button("Check limits with providers…", systemImage: "arrow.triangle.2.circlepath.circle", action: checkLimits)
                        .disabled(checkingLimits)
                } label: {
                    buttonLabel
                } primaryAction: {
                    refresh()
                }
                .menuStyle(.button)
            } else {
                Button(action: refresh) { buttonLabel }
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(isRefreshing)
        .fixedSize()
    }

    private var buttonLabel: some View {
        Label {
            Text(freshness.buttonTitle)
        } icon: {
            if isRefreshing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .font(.subheadline.weight(.semibold))
    }
}

extension View {
    @ViewBuilder
    func freshnessHeader(session: ServerSession, scope: RefreshScope, credentialIDs: [String]? = nil, reload: (@MainActor () async -> Void)? = nil) -> some View {
        #if os(iOS)
        safeAreaBar(edge: .top) {
            FreshnessHeader(session: session, scope: scope, credentialIDs: credentialIDs, reload: reload)
        }
        #else
        self
        #endif
    }
}
