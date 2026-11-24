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

    private var showsAccountCards: Bool {
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
    }

    private func content(layout: OverviewLayout, now: Date) -> some View {
        let accounts = session.accountSummaries
        let quota = session.quotaOverview(at: now)
        let overviews = ProviderOverview.all(pools: quota.pools, accounts: accounts, now: now)
        let ordered = session.orderedAccounts(provider: nil, routerOrder: routerOrder.isOn, now: now)
        return VStack(alignment: .leading, spacing: compactWidth ? 12 : 16) {
            SessionStatusBanner(session: session, scope: .accounts)
            ProviderRefreshStatus(session: session)
            providerCards(overviews, layout: layout, order: ordered.map(\.id))
            if showsAccountCards {
                AccountCardGroups(session: session, ordered: ordered, now: now)
            }
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
        content
            .navigationTitle(Text(verbatim: session.profile.isDemo ? String(localized: "Demo server") : session.profile.name))
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
    }
}
