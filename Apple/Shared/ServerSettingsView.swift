import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct PendingRoutingChange: Identifiable {
    let strategy: String
    let expectedETag: String?

    var id: String { strategy }
    var isUnconditional: Bool { expectedETag == nil }
}

struct ServerSettingsView: View {
    let session: ServerSession
    @State private var pendingChange: PendingRoutingChange?
    @State private var unconditionalChange: PendingRoutingChange?
    @State private var actionError: Error?
    @State private var saving = false

    var body: some View {
        List {
            SessionStatusSection(session: session, scope: .settings)
            if let actionError {
                Section { Text(actionError.userMessage).foregroundStyle(.red) }
            }
            Section {
                if session.routingLoaded, let routing = session.routing {
                    Picker("Strategy", selection: Binding(get: { routing.strategy }, set: { pendingChange = PendingRoutingChange(strategy: $0, expectedETag: routing.etag) })) {
                        ForEach(strategies(including: routing.strategy), id: \.self) { strategy in
                            Text(strategyLabel(strategy)).tag(strategy)
                        }
                    }
                    .disabled(saving)
                } else if session.routingLoaded {
                    Text("This server does not expose its routing strategy through the v8 management API.")
                        .foregroundStyle(.secondary)
                } else {
                    NotLoadedRow(phase: session.loadPhase(for: .settings, loaded: false))
                }
            } header: {
                Text("Routing")
            } footer: {
                if session.routing?.isExplicit == false {
                    Text("The server's config file does not set a routing strategy, so the proxy uses its default, round robin. Choosing one writes it to the config file.")
                } else {
                    Text("How the proxy picks among accounts that can serve a request. Changes are written to the server's config file.")
                }
            }
            Section {
                LabeledContent("Management key") {
                    Text(session.profile.isDemo ? "Not needed for the demo" : "Stored in this device's Keychain")
                }
                if let count = session.clientKeyCount {
                    LabeledContent("Client keys on the server") {
                        Text(count, format: .number)
                    }
                }
            } header: {
                Text("Keys")
            } footer: {
                Text("Proxy Gauge never reads or shows client key values. Servers that publish client-key policies also show how many keys are configured.")
            }
            Section("Server") {
                LabeledContent("Address") { Text(verbatim: session.profile.isDemo ? "–" : session.profile.baseURL.absoluteString) }
                LabeledContent("Version") { Text(verbatim: session.version?.version ?? "–") }
                if let buildDate = session.version?.buildDate {
                    LabeledContent("Built") { Text(verbatim: buildDate) }
                }
            }
        }
        .confirmationDialog(
            Text("Change the routing strategy?"),
            isPresented: Binding(get: { pendingChange != nil }, set: { if !$0 { pendingChange = nil } }),
            titleVisibility: .visible,
            presenting: pendingChange
        ) { change in
            Button {
                confirm(change)
            } label: {
                Text("Use \(Text(strategyLabel(change.strategy)))")
            }
        } message: { _ in
            Text("The proxy applies the new strategy to the next requests.")
        }
        .alert(
            Text("Write without a version check?"),
            isPresented: Binding(get: { unconditionalChange != nil }, set: { if !$0 { unconditionalChange = nil } }),
            presenting: unconditionalChange
        ) { change in
            Button(role: .destructive) {
                apply(change)
            } label: {
                Text("Write anyway")
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The server did not report a configuration version, so this write is unconditional: if someone changed the routing strategy on the server since it was read here, their change is overwritten.")
        }
    }

    private func strategies(including current: String) -> [String] {
        ManagementClient.routingStrategies.contains(current) ? ManagementClient.routingStrategies : ManagementClient.routingStrategies + [current]
    }

    private func strategyLabel(_ strategy: String) -> LocalizedStringResource {
        switch strategy {
        case "round-robin": "Round robin"
        case "weighted-round-robin": "Weighted round robin"
        case "fill-first": "Fill first"
        default: LocalizedStringResource(stringLiteral: strategy)
        }
    }

    private func confirm(_ change: PendingRoutingChange) {
        if change.isUnconditional {
            unconditionalChange = change
        } else {
            apply(change)
        }
    }

    private func apply(_ change: PendingRoutingChange) {
        saving = true
        actionError = nil
        Task {
            defer { saving = false }
            do {
                try await session.setRoutingStrategy(change.strategy, expectedETag: change.expectedETag)
            } catch {
                actionError = error
            }
        }
    }
}
