import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct AccountsView: View {
    let session: ServerSession

    var body: some View {
        AccountCardsByProvider(session: session)
    }
}

struct AccountCardsByProvider: View {
    let session: ServerSession
    private let routerOrder: RouterOrderStorage
    @State private var filter = ProviderFilterBar.all

    init(session: ServerSession) {
        self.session = session
        routerOrder = RouterOrderStorage(serverID: session.profile.id)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: BoardWidth.clockTick)) { context in
            content(now: context.date)
        }
        .background(BoardStyle.pageBackground)
    }

    private func content(now: Date) -> some View {
        let ordered = session.orderedAccounts(provider: nil, routerOrder: routerOrder.isOn, now: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SessionStatusBanner(session: session, scope: .accounts)
                ProviderRefreshStatus(session: session)
                if !session.accountsLoaded {
                    NotLoadedRow(phase: session.loadPhase(for: .accounts, loaded: false))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .boardCard()
                } else if ordered.isEmpty {
                    ContentUnavailableView("No accounts", systemImage: "person.crop.circle.badge.questionmark", description: Text("Add provider accounts on the server, then refresh."))
                } else {
                    PageHeaderRow(accounts: session.accountSummaries, filter: $filter)
                }
                AccountCardGroups(session: session, ordered: ordered, now: now, provider: AccountSummary.shownProvider(filter, in: session.accountSummaries))
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom)
        }
    }
}

struct PageHeaderRow: View {
    let accounts: [AccountSummary]
    @Binding var filter: String

    var body: some View {
        Group {
            #if os(macOS)
            HStack(spacing: 16) {
                PageStatusLine(status: AccountsStatus(accounts))
                Spacer(minLength: 8)
                ProviderFilterBar(accounts: accounts, selection: $filter)
            }
            #else
            PageStatusLine(status: AccountsStatus(accounts))
            #endif
        }
        .onChange(of: AccountSummary.providers(accounts), initial: true) {
            if AccountSummary.shownProvider(filter, in: accounts) == nil, filter != ProviderFilterBar.all {
                filter = ProviderFilterBar.all
            }
        }
    }
}

struct AccountCardGroups: View {
    let session: ServerSession
    let ordered: [OrderedAccount]
    let now: Date
    var provider: String?
    var showsPools = false
    var routerOrder = false

    var body: some View {
        let accounts = session.accountSummaries
        let providers = AccountSummary.providers(accounts).filter { provider == nil || $0 == provider }
        let mode = session.cardOrderMode(routerOrder: routerOrder)
        let quota = showsPools ? session.quotaOverview(at: now).pools : []
        ForEach(providers, id: \.self) { provider in
            let entries = ordered.filter { $0.account.provider == provider }
            if !entries.isEmpty {
                let pools = QuotaSlots.pools(provider: provider, accounts: accounts, at: now)
                VStack(alignment: .leading, spacing: PanelStyle.cardSpacing) {
                    if showsPools {
                        NavigationLink {
                            ProviderDetailView(session: session, provider: provider)
                        } label: {
                            ProviderPanelHeader(
                                pools: pools,
                                overview: quota.first { $0.provider == provider }.map { ProviderOverview(pool: $0, accounts: accounts.filter { $0.provider == provider }, now: now) },
                                mode: mode,
                                canRefreshLimits: session.supportsLimitsRefresh,
                                showsChevron: true
                            )
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ProviderSectionTitle(provider: provider, accounts: pools.accounts, loaded: pools.loaded)
                            .padding(.horizontal, 4)
                    }
                    AccountCardGrid(session: session, entries: entries, slots: [provider: pools.slots])
                }
                .padding(.top, 8)
            }
        }
    }
}

struct AccountCardGrid: View {
    let session: ServerSession?
    let entries: [OrderedAccount]
    var slots: [String: [WindowSlot]] = [:]
    @ScaledMetric(relativeTo: .body) private var minWidth = PanelStyle.cardMinWidth
    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var maxColumns: Int? {
        #if os(iOS)
        guard BoardWidth.isCompact(horizontalSizeClass) else { return nil }
        return dynamicTypeSize.isAccessibilitySize ? 1 : 2
        #else
        nil
        #endif
    }

    var body: some View {
        EqualHeightGrid(minItemWidth: minWidth, maxItemWidth: PanelStyle.cardMaxWidth, maxColumns: maxColumns, spacing: PanelStyle.cardSpacing) {
            ForEach(entries) { entry in
                linked(entry.account) {
                    AccountQuotaCard(account: entry.account, badge: entry.badge, session: session, slots: slotList(for: entry.account.provider), opensDetail: opensDetail)
                }
            }
        }
        .padding(.top, 4)
    }

    private func slotList(for provider: String) -> [WindowSlot] {
        if let known = slots[provider] { return known }
        return QuotaSlots.slots(provider: provider, accounts: entries.map(\.account))
    }

    private var opensDetail: Bool {
        session?.profile.authMode == .management
    }

    @ViewBuilder
    private func linked(_ account: AccountSummary, @ViewBuilder label: () -> some View) -> some View {
        if let session, opensDetail {
            NavigationLink {
                AccountDetailView(session: session, credentialID: account.id)
            } label: {
                label()
            }
            .buttonStyle(.plain)
        } else {
            label()
        }
    }
}
