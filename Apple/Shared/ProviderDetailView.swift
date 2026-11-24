import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct ProviderDetailView: View {
    let session: ServerSession
    let provider: String

    var body: some View {
        ProviderCardsView(session: session, provider: provider)
    }
}

struct ProviderCardsView: View {
    let session: ServerSession
    let provider: String
    private let routerOrder: RouterOrderStorage

    init(session: ServerSession, provider: String) {
        self.session = session
        self.provider = provider
        routerOrder = RouterOrderStorage(serverID: session.profile.id)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: BoardWidth.clockTick)) { context in
            content(now: context.date)
        }
        .background(BoardStyle.pageBackground)
        .navigationTitle(Text(verbatim: ProviderCatalog.displayName(provider)))
        .navigationSubtitle(Text(verbatim: session.profile.isDemo ? String(localized: "Demo server") : session.profile.name))
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .refreshable { await session.refresh(.accounts, trigger: .manual) }
        .freshnessHeader(session: session, scope: session.headroomScope)
    }

    private func content(now: Date) -> some View {
        let quota = session.quotaOverview(at: now)
        let accounts = session.accountSummaries.filter { $0.provider == provider }
        let pool = quota.pools.first { $0.provider == provider }
        let overview = pool.map { ProviderOverview(pool: $0, accounts: accounts, now: now) }
        let mode = session.cardOrderMode(routerOrder: routerOrder.isOn)
        let ordered = AccountOrder.ordered(accounts, mode: mode, now: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SessionStatusBanner(session: session, scope: .accounts)
                ProviderRefreshStatus(session: session)
                if let overview {
                    hero(overview, order: ordered.map(\.id))
                }
                if !ordered.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Accounts")
                            .font(.board(.title3).weight(.bold))
                        Spacer(minLength: 8)
                        Text(mode.caption)
                            .font(.board(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
                    AccountCardGrid(session: session, entries: ordered)
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom)
        }
    }

    private func hero(_ overview: ProviderOverview, order: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: overview.pool.usableAccounts.formatted())
                            .font(.board(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                        Text("of \(overview.pool.totalAccounts.formatted())")
                            .font(.board(.title3).weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("accounts usable now")
                        .font(.board(.subheadline))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(overview.chips, id: \.self) { StatusChipView(chip: $0) }
                }
            }
            if overview.pool.windows.isEmpty {
                NoQuotaDataReason(overview: overview, canRefreshLimits: session.supportsLimitsRefresh)
                    .font(.board(.subheadline))
            }
            ForEach(overview.pool.windows) { window in
                PoolWindowRow(window: window, overview: overview, order: order)
            }
        }
        .boardCard()
    }
}
