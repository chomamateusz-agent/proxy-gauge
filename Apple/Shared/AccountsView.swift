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
                }
                AccountCardGroups(session: session, ordered: ordered, now: now)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
}

struct AccountCardGroups: View {
    let session: ServerSession
    let ordered: [OrderedAccount]
    let now: Date

    var body: some View {
        let pools = session.quotaOverview(at: now).pools
        let providers = session.accountSummaries.reduce(into: [String]()) { list, account in
            if !list.contains(account.provider) { list.append(account.provider) }
        }
        ForEach(providers, id: \.self) { provider in
            let entries = ordered.filter { $0.account.provider == provider }
            let pool = pools.first { $0.provider == provider }
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    header(provider, usable: pool?.usableAccounts ?? entries.count { $0.section == .usable }, total: pool?.totalAccounts ?? entries.count)
                    AccountCardGrid(session: session, entries: entries)
                }
            }
        }
    }

    private func header(_ provider: String, usable: Int, total: Int) -> some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: provider, size: 24)
            Text(verbatim: ProviderCatalog.displayName(provider))
                .font(.board(.title3).weight(.bold))
            Spacer(minLength: 8)
            Text("\(usable) of \(total) usable")
                .font(.board(.subheadline))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct AccountCardGrid: View {
    let session: ServerSession?
    let entries: [OrderedAccount]

    var body: some View {
        EqualHeightGrid(minItemWidth: BoardStyle.accountCardMinWidth, maxItemWidth: BoardStyle.accountCardMaxWidth) {
            ForEach(entries) { entry in
                linked(entry.account) {
                    AccountQuotaCard(account: entry.account, badge: entry.badge, session: session, opensDetail: opensDetail)
                }
            }
        }
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
