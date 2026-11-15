import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

enum BoardWidth {
    static let minimumForAccountsBoard: CGFloat = 640

    #if os(iOS)
    static func isCompact(_ sizeClass: UserInterfaceSizeClass?) -> Bool { sizeClass == .compact }
    #endif
}

struct OverviewView: View {
    let session: ServerSession
    @AppStorage(AccountsLayout.storageKey) private var storedLayout = AccountsLayout.cards.rawValue
    @State private var width: CGFloat = 0
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

    private var showsAccountsBoard: Bool {
        !compactWidth && width >= BoardWidth.minimumForAccountsBoard
    }

    var body: some View {
        let accounts = session.accountSummaries
        let phase = session.loadPhase(for: .accounts, loaded: session.accountsLoaded)
        let quota = session.quotaOverview(at: .now)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SessionStatusBanner(session: session, scope: .accounts)
                ProviderRefreshStatus(session: session)
                ServerFacts(session: session)
                if let savedAt = quota.savedAt {
                    SavedDataNote(savedAt: savedAt, refreshesAutomatically: session.refreshesAutomatically)
                }
                DashboardSection(title: "Pooled capacity") {
                    DashboardInfoButton()
                } content: {
                    ProviderTilesGrid(pools: quota.pools, headroom: quota.headroom, accounts: accounts, phase: phase)
                }
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
            }
            .padding()
        }
        .background(BoardStyle.pageBackground)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
        .toolbar {
            if showsAccountsBoard {
                ToolbarItem {
                    AccountsLayoutPicker(storedLayout: $storedLayout, compactWidth: compactWidth)
                }
            }
            if session.supportsLimitsRefresh {
                ToolbarItem {
                    RefreshLimitsButton(session: session)
                }
            }
        }
    }
}
