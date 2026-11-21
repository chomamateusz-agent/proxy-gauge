import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct AccountsView: View {
    let session: ServerSession

    var body: some View {
        #if os(iOS)
        AccountCardsByProvider(session: session)
        #else
        AccountsBoardView(session: session)
        #endif
    }
}

struct AccountsBoardView: View {
    let session: ServerSession
    @State private var filter: CredentialState?
    @State private var limitsRequest: LimitsRefreshRequest?
    @AppStorage(AccountsLayout.storageKey) private var storedLayout = AccountsLayout.cards.rawValue
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

    private var layout: AccountsLayout { AccountsLayout.resolve(storedLayout, compactWidth: compactWidth) }

    var body: some View {
        Group {
            if layout == .list {
                listBody
            } else {
                boardBody
            }
        }
        .toolbar {
            ToolbarItem {
                AccountsLayoutPicker(storedLayout: $storedLayout, compactWidth: compactWidth)
            }
            if session.supportsLimitsRefresh {
                ToolbarItem {
                    RefreshLimitsButton(session: session)
                }
            }
        }
    }

    private var visibleAccounts: [AccountSummary] {
        session.accountSummaries.filter { filter == nil || $0.state == filter }
    }

    private var filterPicker: some View {
        Picker("State", selection: $filter) {
            Text("All").tag(CredentialState?.none)
            ForEach(CredentialState.allCases, id: \.self) { state in
                Text(state.label).tag(CredentialState?.some(state))
            }
        }
        .pickerStyle(.menu)
    }

    private var boardBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SessionStatusBanner(session: session, scope: .accounts)
                ProviderRefreshStatus(session: session)
                if session.accountsLoaded {
                    filterPicker
                        .fixedSize()
                    AccountsBoard(accounts: visibleAccounts, layout: layout, session: session)
                    if session.credentials.isEmpty {
                        noAccounts
                    }
                } else {
                    NotLoadedRow(phase: session.loadPhase(for: .accounts, loaded: false))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .boardCard()
                }
            }
            .padding()
        }
        .background(BoardStyle.pageBackground)
    }

    private var listBody: some View {
        List {
            SessionStatusSection(session: session, scope: .accounts)
            if !session.refreshingLimits.isEmpty || session.limitsRefreshError != nil || session.proxyRefusalNotice(at: .now) != nil {
                Section { ProviderRefreshStatus(session: session) }
            }
            Section {
                if session.accountsLoaded {
                    filterPicker
                } else {
                    NotLoadedRow(phase: session.loadPhase(for: .accounts, loaded: false))
                }
            }
            ForEach(groups, id: \.provider) { group in
                Section {
                    ForEach(group.accounts) { account in
                        NavigationLink {
                            AccountDetailView(session: session, credentialID: account.id)
                        } label: {
                            AccountSummaryRow(account: account)
                                .padding(.vertical, 2)
                        }
                        .contextMenu {
                            RefreshLimitsMenuItem(session: session, account: account) { limitsRequest = $0 }
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        ProviderBadge(provider: group.provider, size: 18)
                        Text(ProviderCatalog.displayName(group.provider))
                    }
                }
            }
            if session.accountsLoaded && session.credentials.isEmpty {
                noAccounts
            }
        }
        .limitsRefreshSheet(session: session, request: $limitsRequest)
    }

    private var noAccounts: some View {
        ContentUnavailableView("No accounts", systemImage: "person.crop.circle.badge.questionmark", description: Text("Add provider accounts on the server, then refresh."))
    }

    private var groups: [(provider: String, accounts: [AccountSummary])] {
        let visible = visibleAccounts
        var order: [String] = []
        for account in visible where !order.contains(account.provider) {
            order.append(account.provider)
        }
        return order.map { provider in (provider, visible.filter { $0.provider == provider }) }
    }
}

struct AccountCardsByProvider: View {
    let session: ServerSession
    private let routerOrder: RouterOrderStorage

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
        let pools = session.quotaOverview(at: now).pools
        let providers = session.accountSummaries.reduce(into: [String]()) { list, account in
            if !list.contains(account.provider) { list.append(account.provider) }
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                SessionStatusBanner(session: session, scope: .accounts)
                ProviderRefreshStatus(session: session)
                if !session.accountsLoaded {
                    NotLoadedRow(phase: session.loadPhase(for: .accounts, loaded: false))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .boardCard()
                } else if ordered.isEmpty {
                    ContentUnavailableView("No accounts", systemImage: "person.crop.circle.badge.questionmark", description: Text("Add provider accounts on the server, then refresh."))
                }
                ForEach(providers, id: \.self) { provider in
                    let entries = ordered.filter { $0.account.provider == provider }
                    let pool = pools.first { $0.provider == provider }
                    header(provider, usable: pool?.usableAccounts ?? entries.count { $0.section == .usable }, total: pool?.totalAccounts ?? entries.count)
                    ForEach(entries) { entry in
                        NavigationLink {
                            AccountDetailView(session: session, credentialID: entry.account.id)
                        } label: {
                            AccountQuotaCard(account: entry.account, badge: entry.badge, session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private func header(_ provider: String, usable: Int, total: Int) -> some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: provider, size: 24)
            Text(verbatim: ProviderCatalog.displayName(provider))
                .font(.title3.weight(.bold))
            Spacer(minLength: 8)
            Text("\(usable) of \(total) usable")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
