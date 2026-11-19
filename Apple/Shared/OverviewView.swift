import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

enum BoardWidth {
    static let minimumForAccountsBoard: CGFloat = 640
    static let clockTick: TimeInterval = 30

    #if os(iOS)
    static func isCompact(_ sizeClass: UserInterfaceSizeClass?) -> Bool { sizeClass == .compact }
    #endif
}

struct OverviewView: View {
    let session: ServerSession
    @AppStorage(AccountsLayout.storageKey) private var storedLayout = AccountsLayout.cards.rawValue
    @AppStorage(OverviewLayout.storageKey) private var storedOverviewLayout = OverviewLayout.standard.rawValue
    @State private var width: CGFloat = 0
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var compactWidth: Bool {
        #if os(iOS)
        BoardWidth.isCompact(horizontalSizeClass)
        #else
        false
        #endif
    }

    private var showsAccountsBoard: Bool {
        !compactWidth && width >= BoardWidth.minimumForAccountsBoard
    }

    var body: some View {
        let layout = OverviewLayout.resolve(storedOverviewLayout)
        ScrollView {
            TimelineView(.periodic(from: .now, by: BoardWidth.clockTick)) { context in
                content(layout: layout, now: context.date)
            }
        }
        .background(BoardStyle.pageBackground)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
        .modifier(ServerTitle(session: session))
        .toolbar {
            if showsAccountsBoard {
                ToolbarItem {
                    AccountsLayoutPicker(storedLayout: $storedLayout, compactWidth: compactWidth)
                }
            }
            if session.supportsLimitsRefresh {
                ToolbarItem {
                    RefreshLimitsButton(session: session)
                }
            }
            if layout == .answerFirst {
                ToolbarItem {
                    ServerInfoButton(session: session)
                }
            }
        }
    }

    private func content(layout: OverviewLayout, now: Date) -> some View {
        let accounts = session.accountSummaries
        let quota = session.quotaOverview(at: now)
        let overviews = ProviderOverview.all(pools: quota.pools, accounts: accounts, now: now)
        return VStack(alignment: .leading, spacing: 16) {
            SessionStatusBanner(session: session, scope: .accounts)
            ProviderRefreshStatus(session: session)
            if let savedAt = quota.savedAt {
                SavedDataNote(savedAt: savedAt, refreshesAutomatically: session.refreshesAutomatically)
            }
            providerCards(overviews, layout: layout)
            if showsAccountsBoard && !accounts.isEmpty {
                DashboardSection(title: "Accounts") {
                    AccountsBoard(
                        accounts: accounts,
                        layout: AccountsLayout.resolve(storedLayout, compactWidth: compactWidth),
                        session: session,
                        cardMinWidth: BoardStyle.compactCardMinWidth
                    )
                }
            }
            if layout != .answerFirst {
                ServerInfoCard(session: session)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    @ViewBuilder
    private func providerCards(_ overviews: [ProviderOverview], layout: OverviewLayout) -> some View {
        let phase = session.loadPhase(for: .accounts, loaded: session.accountsLoaded)
        if overviews.isEmpty {
            Group {
                if phase == .loaded {
                    Text("No accounts on this server yet.")
                        .foregroundStyle(.secondary)
                } else {
                    NotLoadedRow(phase: phase)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .boardCard()
        } else {
            EqualHeightGrid(minItemWidth: layout.cardMinWidth) {
                ForEach(overviews) { overview in
                    ProviderOverviewCard(overview: overview, layout: layout, session: session)
                }
            }
        }
    }
}

struct ServerTitle: ViewModifier {
    let session: ServerSession

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            content
                .navigationTitle(Text(verbatim: session.profile.isDemo ? String(localized: "Demo server") : session.profile.name))
                .navigationSubtitle(subtitle(at: context.date))
        }
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }

    private func subtitle(at now: Date) -> Text {
        if let lastRefresh = session.lastRefresh {
            return Text("Updated \(ElapsedTime.text(from: lastRefresh, to: now)) ago")
        }
        return session.isRefreshing ? Text("Refreshing…") : Text("Not refreshed yet")
    }
}
