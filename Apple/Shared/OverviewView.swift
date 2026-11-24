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
    @State private var width: CGFloat = 0
    @State private var filter = ProviderFilterBar.all
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
        ScrollView {
            TimelineView(.periodic(from: .now, by: BoardWidth.clockTick)) { context in
                content(now: context.date)
            }
        }
        .background(BoardStyle.pageBackground)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
        .modifier(ServerTitle(session: session))
    }

    private func content(now: Date) -> some View {
        let accounts = session.accountSummaries
        let ordered = session.orderedAccounts(provider: nil, routerOrder: routerOrder.isOn, now: now)
        let shown = AccountSummary.shownProvider(filter, in: accounts)
        return VStack(alignment: .leading, spacing: compactWidth ? 12 : 16) {
            SessionStatusBanner(session: session, scope: .accounts)
            ProviderRefreshStatus(session: session)
            if !accounts.isEmpty {
                PageHeaderRow(accounts: accounts, filter: $filter)
                if showsAccountCards {
                    AccountCardGroups(session: session, ordered: ordered, now: now, provider: shown, showsPools: true, routerOrder: routerOrder.isOn)
                } else {
                    providerHeaders(accounts: accounts, provider: shown, now: now)
                }
            } else if let saved = savedAccounts(at: now) {
                SavedDataNote(savedAt: saved.savedAt, refreshesAutomatically: session.refreshesAutomatically)
                providerHeaders(accounts: saved.accounts, provider: nil, now: now, opensDetail: false)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func savedAccounts(at now: Date) -> (savedAt: Date, accounts: [AccountSummary])? {
        guard let savedAt = session.quotaOverview(at: now).savedAt,
              let poolAccounts = session.savedSnapshot?.poolAccounts, !poolAccounts.isEmpty
        else { return nil }
        return (savedAt, AccountSummary.saved(poolAccounts))
    }

    @ViewBuilder
    private var empty: some View {
        let phase = session.loadPhase(for: .accounts, loaded: session.accountsLoaded)
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
    }

    private func providerHeaders(accounts: [AccountSummary], provider shown: String?, now: Date, opensDetail: Bool = true) -> some View {
        let quota = session.quotaOverview(at: now).pools
        let mode = session.cardOrderMode(routerOrder: routerOrder.isOn)
        return VStack(spacing: compactWidth ? 10 : BoardStyle.spacing) {
            ForEach(AccountSummary.providers(accounts).filter { shown == nil || $0 == shown }, id: \.self) { provider in
                let members = accounts.filter { $0.provider == provider }
                let header = ProviderPanelHeader(
                    pools: QuotaSlots.pools(provider: provider, accounts: accounts, at: now),
                    overview: quota.first { $0.provider == provider }.map { ProviderOverview(pool: $0, accounts: members, now: now) },
                    mode: mode,
                    canRefreshLimits: session.supportsLimitsRefresh,
                    showsChevron: opensDetail
                )
                if opensDetail {
                    NavigationLink {
                        ProviderDetailView(session: session, provider: provider)
                    } label: {
                        header.contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } else {
                    header
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
