import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct AccountsView: View {
    let session: ServerSession
    @State private var filter: CredentialState?

    var body: some View {
        List {
            SessionStatusSection(session: session, scope: .accounts)
            Section {
                Picker("State", selection: $filter) {
                    Text("All").tag(CredentialState?.none)
                    ForEach(CredentialState.allCases, id: \.self) { state in
                        Text(state.label).tag(CredentialState?.some(state))
                    }
                }
                .pickerStyle(.menu)
            }
            ForEach(groups, id: \.provider) { group in
                Section {
                    ForEach(group.credentials) { credential in
                        NavigationLink {
                            AccountDetailView(session: session, credentialID: credential.id)
                        } label: {
                            AccountRow(credential: credential)
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
                ContentUnavailableView("No accounts", systemImage: "person.crop.circle.badge.questionmark", description: Text("Add provider accounts on the server, then refresh."))
            }
        }
    }

    private var groups: [(provider: String, credentials: [Credential])] {
        let now = Date.now
        let visible = session.credentials.filter { filter == nil || $0.state(at: now) == filter }
        return AccountCounts.tally(visible, now: now).map { counts in
            (counts.provider, visible.filter { $0.provider == counts.provider }.sorted { $0.displayName < $1.displayName })
        }
    }
}

struct AccountRow: View {
    let credential: Credential

    var body: some View {
        let now = Date.now
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: credential.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                StateBadge(state: credential.state(at: now))
            }
            if let cooldown = credential.activeCredentialCooldown(at: now), let retryAt = cooldown.retryAt {
                Text("Cooling down for \(Text(retryAt, style: .relative))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(credential.quotaBars.sortedForDisplay().filter { [.session5h, .weekly].contains($0.window) }) { bar in
                QuotaBarRow(bar: bar)
            }
        }
        .padding(.vertical, 2)
    }
}
