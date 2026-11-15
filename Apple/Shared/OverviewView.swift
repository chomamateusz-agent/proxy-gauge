import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct OverviewView: View {
    let session: ServerSession

    var body: some View {
        List {
            SessionStatusSection(session: session, scope: .accounts)
            Section("Server") {
                LabeledContent("Version") {
                    Text(verbatim: session.version?.version ?? "–")
                }
                if let commit = session.version?.commit {
                    LabeledContent("Commit") { Text(verbatim: commit).monospaced() }
                }
                LabeledContent("Accounts") {
                    if session.accountsLoaded {
                        Text(session.credentials.count, format: .number)
                    } else {
                        Text(verbatim: "–")
                    }
                }
                LabeledContent("Last refresh") {
                    RefreshFooter(lastRefresh: session.lastRefresh, isRefreshing: session.isRefreshing)
                }
                if let observedAt = session.observedAt {
                    LabeledContent("Server time") {
                        Text(observedAt, format: .dateTime.hour().minute().second())
                    }
                }
            }
            PooledCapacitySection(pools: session.pools, phase: session.loadPhase(for: .accounts, loaded: session.accountsLoaded))
            let headroom = session.headroom
            Section {
                if headroom.isEmpty {
                    if session.accountsLoaded {
                        Text("No accounts on this server yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        NotLoadedRow(phase: session.loadPhase(for: .accounts, loaded: false))
                    }
                }
                ForEach(headroom) { provider in
                    ProviderHeadroomRow(headroom: provider)
                        .padding(.vertical, 2)
                }
            } header: {
                Text("Headroom per provider")
            } footer: {
                if session.accountsLoaded && !headroom.isEmpty {
                    Text("Best remaining quota across usable accounts, from rate-limit headers the proxy already observed. Proxy Gauge never asks providers for quota.")
                }
            }
            let accountCounts = session.accountCounts
            if !accountCounts.isEmpty {
                Section("Accounts by state") {
                    ForEach(accountCounts) { counts in
                        AccountCountsRow(counts: counts)
                    }
                }
            }
        }
    }
}

struct PooledCapacitySection: View {
    let pools: [ProviderPool]
    let phase: LoadPhase

    var body: some View {
        Section {
            if pools.isEmpty {
                if phase == .loaded {
                    Text("No accounts on this server yet.")
                        .foregroundStyle(.secondary)
                } else {
                    NotLoadedRow(phase: phase)
                }
            }
            ForEach(pools) { pool in
                PooledProviderRow(pool: pool)
                    .padding(.vertical, 2)
            }
        } header: {
            Text("Pooled capacity")
        } footer: {
            if !pools.isEmpty {
                Text("Remaining quota of every enabled account added up: three accounts make \(HeadroomStyle.percentText(300)). A cooling account counts as 0 until its cooldown ends, a window whose reset has passed counts as full, and an account without a sample is listed separately.")
            }
        }
    }
}

private struct AccountCountsRow: View {
    let counts: AccountCounts

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: counts.provider, size: 24)
            Text(ProviderCatalog.displayName(counts.provider))
                .lineLimit(1)
            Spacer()
            ForEach(CredentialState.allCases, id: \.self) { state in
                if counts.count(state) > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: state.symbol)
                        Text(counts.count(state), format: .number)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(state.color)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(Text(state.label)): \(counts.count(state))"))
                }
            }
        }
    }
}
