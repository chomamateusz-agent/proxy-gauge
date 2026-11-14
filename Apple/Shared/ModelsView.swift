import ProxyGaugeCore
import SwiftUI

struct ModelsView: View {
    let session: ServerSession
    @State private var query = ""

    var body: some View {
        List {
            SessionStatusSection(session: session)
            Section {
                ForEach(filtered) { model in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: model.id)
                            .font(.callout.monospaced())
                        if let detail = detail(for: model) {
                            Text(verbatim: detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !session.modelFailedAccounts.isEmpty {
                    Label {
                        Text("Could not read the models of \(session.modelFailedAccounts.joined(separator: ", ")).")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
                if session.modelsLoaded && session.models.isEmpty {
                    Text("The server lists no models.").foregroundStyle(.secondary)
                } else if !session.modelsLoaded {
                    NotLoadedRow(phase: session.loadPhase(loaded: false))
                }
            } header: {
                Text("Models: \(session.models.count)")
            } footer: {
                session.profile.authMode == .management
                    ? Text("Collected from the model registry of each enabled account.")
                    : Text("What this client key may call, from /v1/models.")
            }
        }
        .searchable(text: $query, prompt: Text("Filter models"))
    }

    private var filtered: [ModelInfo] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return session.models }
        return session.models.filter { $0.id.localizedCaseInsensitiveContains(needle) }
    }

    private func detail(for model: ModelInfo) -> String? {
        if let providers = session.modelProviders[model.id], !providers.isEmpty {
            return providers.sorted().map(ProviderCatalog.displayName).joined(separator: ", ")
        }
        return model.ownedBy
    }
}
