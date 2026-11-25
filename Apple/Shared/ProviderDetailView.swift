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
        .freshnessHeader(session: session, scope: session.headroomScope, credentialIDs: session.accountSummaries.filter { $0.provider == provider }.map(\.id))
    }

    private func content(now: Date) -> some View {
        let quota = session.quotaOverview(at: now)
        let accounts = session.accountSummaries.filter { $0.provider == provider }
        let overview = quota.pools.first { $0.provider == provider }.map { ProviderOverview(pool: $0, accounts: accounts, now: now) }
        let mode = session.cardOrderMode(routerOrder: routerOrder.isOn)
        let ordered = AccountOrder.ordered(accounts, mode: mode, now: now)
        let pools = QuotaSlots.pools(provider: provider, accounts: accounts, at: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SessionStatusBanner(session: session, scope: .accounts)
                ProviderRefreshStatus(session: session)
                if !accounts.isEmpty {
                    ProviderPanelHeader(pools: pools, overview: overview, mode: mode, canRefreshLimits: session.supportsLimitsRefresh) {
                        if let overview {
                            availability(overview)
                        }
                    }
                }
                if !ordered.isEmpty {
                    AccountCardGrid(session: session, entries: ordered, slots: [provider: pools.slots])
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom)
        }
    }

    @ViewBuilder
    private func availability(_ overview: ProviderOverview) -> some View {
        Divider()
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                usable(overview)
                Spacer(minLength: 6)
                StatusChipRow(chips: overview.chips).fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                usable(overview)
                StatusChipRow(chips: overview.chips).fixedSize()
            }
        }
        ForEach(overview.pool.windows.filter(\.hasBlockedQuota)) { window in
            if let usable = window.usableShareOfKnown, window.knownAccounts > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    window.title
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(verbatim: String(localized: "\(HeadroomStyle.percentText(usable * 100)) usable now · \(HeadroomStyle.percentText(window.blockedPercent / Double(window.knownAccounts))) blocked"))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                .font(.board(.footnote))
                .accessibilityElement(children: .combine)
            }
        }
        ComebackFooter(overview: overview)
    }

    private func usable(_ overview: ProviderOverview) -> some View {
        Text("\(overview.pool.usableAccounts) of \(overview.pool.totalAccounts) usable")
            .font(.board(.subheadline).weight(.semibold).monospacedDigit())
    }
}
