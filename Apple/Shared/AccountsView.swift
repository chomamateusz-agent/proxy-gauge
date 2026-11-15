import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct AccountsView: View {
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
