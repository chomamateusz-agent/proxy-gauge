import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct ServerInfoCard: View {
    let session: ServerSession

    var body: some View {
        DashboardSection(title: "Server") {
            VStack(spacing: 0) {
                ServerFactRows(session: session, includesLastRefresh: false) { title, value in
                    row(title) { value }
                    Divider()
                }
                HStack {
                    Text("Refresh automatically")
                        .accessibilityHidden(true)
                    Spacer(minLength: 8)
                    AutoRefreshToggle(profile: session.profile)
                        .labelsHidden()
                }
                .padding(.vertical, 8)
                Divider()
                NavigationLink {
                    DashboardFootnotesPage()
                } label: {
                    HStack {
                        Text("How these numbers work")
                            .foregroundStyle(.tint)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .background(BoardStyle.cardBackground, in: .rect(cornerRadius: BoardStyle.cornerRadius))
        }
    }

    private func row(_ title: LocalizedStringResource, @ViewBuilder value: () -> some View) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 8)
                value().foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                value().foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ServerInfoSheet: View {
    let session: ServerSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ServerFactRows(session: session, includesLastRefresh: true) { title, value in
                        LabeledContent { value } label: { Text(title) }
                    }
                    AutoRefreshToggle(profile: session.profile)
                }
                Section {
                    NavigationLink("How these numbers work") {
                        DashboardFootnotesPage()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("Server"))
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}

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

struct ServerInfoButton: View {
    let session: ServerSession
    @State private var showsInfo = false

    var body: some View {
        Button("Server", systemImage: "info.circle") { showsInfo = true }
            .help(Text("Server"))
            .sheet(isPresented: $showsInfo) {
                ServerInfoSheet(session: session)
            }
    }
}
