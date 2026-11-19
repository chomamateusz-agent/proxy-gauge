import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct ProviderDetailView: View {
    let session: ServerSession
    let provider: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: BoardWidth.clockTick)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let quota = session.quotaOverview(at: now)
        let accounts = session.accountSummaries.filter { $0.provider == provider }
        let pool = quota.pools.first { $0.provider == provider }
        let overview = pool.map { ProviderOverview(pool: $0, accounts: accounts, now: now) }
        let headroom = quota.headroom.first { $0.provider == provider }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let overview {
                    DashboardSection(title: "Windows") {
                        windows(overview)
                    }
                    if overview.hasAccountColumns {
                        DashboardSection(title: "Accounts by window") {
                            VStack(alignment: .leading, spacing: 10) {
                                AccountMatrix(overview: overview)
                                Divider()
                                ComebackLine(overview: overview)
                            }
                            .boardCard()
                        }
                    }
                }
                if !accounts.isEmpty {
                    DashboardSection(title: "Accounts") {
                        AccountsBoard(accounts: AccountSummary.board(accounts), layout: .list, session: session)
                    }
                }
                if let headroom, headroom.isWorthShowingBesideThePool {
                    BestAccountLine(headroom: headroom)
                        .boardCard()
                }
            }
            .padding()
        }
        .background(BoardStyle.pageBackground)
        .navigationTitle(Text(verbatim: ProviderCatalog.displayName(provider)))
        .navigationSubtitle(subtitle(pool))
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }

    private func subtitle(_ pool: ProviderPool?) -> Text {
        guard let pool else { return Text(verbatim: "") }
        return Text("Accounts: \(pool.totalAccounts) · usable: \(pool.usableAccounts)")
    }

    @ViewBuilder
    private func windows(_ overview: ProviderOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if overview.pool.windows.isEmpty {
                NoQuotaDataReason(overview: overview, canRefreshLimits: session.supportsLimitsRefresh)
                    .font(.subheadline)
            }
            ForEach(Array(overview.pool.windows.enumerated()), id: \.element.id) { index, window in
                if index > 0 { Divider() }
                PooledWindowRow(window: window)
            }
        }
        .boardCard()
    }
}
