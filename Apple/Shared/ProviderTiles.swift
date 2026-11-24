import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct DashboardSection<Content: View, Accessory: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                accessory
            }
            content
        }
    }
}

extension DashboardSection where Accessory == EmptyView {
    init(title: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.title = title
        accessory = EmptyView()
        self.content = content()
    }
}

struct ProviderTilesGrid: View {
    let pools: [ProviderPool]
    let headroom: [ProviderHeadroom]
    let accounts: [AccountSummary]
    let phase: LoadPhase

    var body: some View {
        if pools.isEmpty {
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
            EqualHeightGrid(minItemWidth: pools.count >= BoardStyle.providersForCompactTiles ? BoardStyle.compactTileMinWidth : BoardStyle.tileMinWidth) {
                ForEach(pools) { pool in
                    ProviderTile(
                        pool: pool,
                        headroom: headroom.first { $0.provider == pool.provider },
                        states: states(of: pool.provider)
                    )
                }
            }
        }
    }

    private func states(of provider: String) -> [CredentialState: Int] {
        Dictionary(grouping: accounts.filter { $0.provider == provider }, by: \.state).mapValues(\.count)
    }
}

struct ProviderTile: View {
    let pool: ProviderPool
    let headroom: ProviderHeadroom?
    let states: [CredentialState: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ProviderBadge(provider: pool.provider, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(ProviderCatalog.displayName(pool.provider))
                            .font(.headline)
                        Spacer(minLength: 4)
                        StateCounts(states: states)
                    }
                    AccountCountText(pool: pool)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if pool.windows.isEmpty {
                Group {
                    if pool.accounts == 0 {
                        Text("Every account of this provider is disabled.")
                    } else {
                        Text("No quota data reported yet")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(pool.windows) { window in
                PooledWindowRow(window: window)
            }
            if let headroom, headroom.isWorthShowingBesideThePool {
                Divider()
                BestAccountLine(headroom: headroom)
            }
        }
        .boardCard()
    }
}

struct StateCounts: View {
    let states: [CredentialState: Int]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CredentialState.allCases, id: \.self) { state in
                if let count = states[state], count > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: state.symbol)
                        Text(count, format: .number)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(state.color)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(Text(state.label)): \(count)"))
                }
            }
        }
        .fixedSize()
    }
}

struct DashboardFootnotes: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider percent: what the provider's accounts have left in a window, on a 0 to 100 scale, as the management panel shows it. When every Claude account's plan is known, the average is weighted by plan: Max 20x counts 20, Max 5x counts 5, Pro counts 1. It covers enabled accounts that have not ended and report that window; the caption says how many of the provider's accounts that is. A window whose reset has passed counts as full.")
            Text("Usable now and blocked, in provider details: the share of that quota on accounts that can take requests right now. Quota on an account in cooldown, with another window at its limit, or waiting for a new sign-in is blocked, with how much of it comes back first and when.")
            Text("A Claude or Codex account that reports other windows but no 5-hour window has no 5-hour window running. Its card shows the 5-hour window as full, because its next request starts one, but the provider percent leaves it out until the provider reports the window.")
            Text("Pooled capacity, on the Limits page of a client key: remaining quota of every enabled account added up, so three accounts make \(HeadroomStyle.percentText(300)).")
            Text("Best usable account: the most quota a single account that can take requests right now has left in its tightest window. Shown when at least two accounts can take requests.")
            Text("Passive data: numbers without a mark come from rate-limit headers the proxy already observed while serving requests. Reading them sends nothing to the providers.")
            #if os(iOS)
            Text("Active data: numbers with \(Image(systemName: "antenna.radiowaves.left.and.right")) come from a check with the provider, where the server asks the provider with the account's own sign-in. That happens only when you hold Refresh and choose Check limits with providers, or on a schedule while the app is visible and automatic provider refresh is on for this server in Settings.")
            #else
            Text("Active data: numbers with \(Image(systemName: "antenna.radiowaves.left.and.right")) come from a check with the provider, where the server asks the provider with the account's own sign-in. That happens only when you choose Check limits with providers in the Refresh menu, or on a schedule while the app is visible and automatic provider refresh is on for this server in Settings.")
            #endif
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardInfoButton: View {
    @State private var showsInfo = false

    var body: some View {
        Button("How these numbers work", systemImage: "info.circle") { showsInfo = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(Text("How these numbers work"))
            .popover(isPresented: $showsInfo, arrowEdge: .bottom) {
                ScrollView {
                    DashboardFootnotes()
                        .padding()
                }
                .frame(idealWidth: 420, maxWidth: 480, idealHeight: 400)
                .presentationCompactAdaptation(.popover)
            }
    }
}
