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
    private let routerOrder: RouterOrderStorage
    @AppStorage(AccountsLayout.storageKey) private var storedLayout = AccountsLayout.cards.rawValue
    @AppStorage(OverviewLayout.storageKey) private var storedOverviewLayout = OverviewLayout.standard.rawValue
    @State private var width: CGFloat = 0
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    init(session: ServerSession) {
        self.session = session
        routerOrder = RouterOrderStorage(serverID: session.profile.id)
    }

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
            #if os(macOS)
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
            #endif
        }
    }

    private func content(layout: OverviewLayout, now: Date) -> some View {
        let accounts = session.accountSummaries
        let quota = session.quotaOverview(at: now)
        let overviews = ProviderOverview.all(pools: quota.pools, accounts: accounts, now: now)
        #if os(macOS)
        let order = accounts.map(\.id)
        #else
        let order = session.orderedAccounts(provider: nil, routerOrder: routerOrder.isOn, now: now).map(\.id)
        #endif
        return VStack(alignment: .leading, spacing: compactWidth ? 12 : 16) {
            SessionStatusBanner(session: session, scope: .accounts)
            ProviderRefreshStatus(session: session)
            #if os(macOS)
            if let savedAt = quota.savedAt {
                SavedDataNote(savedAt: savedAt, refreshesAutomatically: session.refreshesAutomatically)
            }
            #endif
            providerCards(overviews, layout: layout, order: order)
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
            #if os(macOS)
            if layout != .answerFirst {
                ServerInfoCard(session: session)
            }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    @ViewBuilder
    private func providerCards(_ overviews: [ProviderOverview], layout: OverviewLayout, order: [String]) -> some View {
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
            EqualHeightGrid(minItemWidth: layout.cardMinWidth, spacing: compactWidth ? 10 : BoardStyle.spacing) {
                ForEach(overviews) { overview in
                    ProviderOverviewCard(overview: overview, layout: layout, session: session, order: order)
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
                #if os(macOS)
                .navigationSubtitle(subtitle(at: context.date))
                #endif
        }
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }

    #if os(macOS)
    private func subtitle(at now: Date) -> Text {
        if let lastRefresh = session.lastRefresh {
            return Text("Updated \(ElapsedTime.text(from: lastRefresh, to: now)) ago")
        }
        return session.isRefreshing ? Text("Refreshing…") : Text("Not refreshed yet")
    }
    #endif
}
