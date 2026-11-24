import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct ServerFactRows<Row: View>: View {
    let session: ServerSession
    let includesLastRefresh: Bool
    @ViewBuilder let row: (LocalizedStringResource, AnyView) -> Row

    var body: some View {
        row("Version", AnyView(Text(verbatim: session.version?.version ?? "–").textSelection(.enabled)))
        if let commit = session.version?.commit {
            row("Commit", AnyView(
                Text(verbatim: String(commit.prefix(12)))
                    .monospaced()
                    .textSelection(.enabled)
                    .help(Text(verbatim: commit))
            ))
        }
        row("Accounts on server", AnyView(accountCount))
        if let observedAt = session.observedAt ?? session.fleetLimits?.generatedAt {
            row("Server time", AnyView(Text(observedAt, format: .dateTime.hour().minute().second())))
        }
        if includesLastRefresh {
            row("Last refresh", AnyView(RefreshFooter(lastRefresh: session.lastRefresh, isRefreshing: session.isRefreshing)))
        }
    }

    @ViewBuilder
    private var accountCount: some View {
        if session.hasLoaded(session.headroomScope) {
            Text(session.accountSummaries.count, format: .number)
        } else {
            Text(verbatim: "–")
        }
    }
}

struct AutoRefreshToggle: View {
    @Environment(AppModel.self) private var model
    let profile: ServerProfile

    var body: some View {
        Toggle("Refresh automatically", isOn: Binding(
            get: { model.refreshesAutomatically(profile) },
            set: { model.setRefreshesAutomatically($0, for: profile) }
        ))
    }
}

struct DashboardFootnotesPage: View {
    var body: some View {
        ScrollView {
            DashboardFootnotes()
                .padding()
        }
        .background(BoardStyle.pageBackground)
        .navigationTitle(Text("How these numbers work"))
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }
}
