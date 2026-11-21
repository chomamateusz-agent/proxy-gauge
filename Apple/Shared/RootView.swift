import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var editor: EditorTarget?
    @State private var pendingDeletion: ServerProfile?
    @State private var deletionError: Error?
    @State private var isAppVisible = true

    var body: some View {
        navigation
            .tracksAppVisibility($isAppVisible)
            .task(id: providerRefreshLoopID) {
                guard let loop = providerRefreshLoopID, loop.isVisible, let profile = model.selectedProfile else { return }
                let session = model.session(for: profile)
                session.reloadProviderChecks()
                guard loop.enabled else { return }
                await session.runAutomaticLimitsRefresh(every: ProviderRefreshLoopID.tick)
            }
            .autoRefresh(
                every: autoRefreshInterval,
                target: autoRefreshTarget,
                repeats: model.selectedProfile.map(model.refreshesAutomatically) ?? false
            ) {
                await refreshSelection(trigger: .automatic)
            }
            .onOpenURL { model.open($0) }
            .sheet(item: $editor) { target in
                ServerEditor(target: target)
            }
            .confirmationDialog(
                "Delete this server?",
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { profile in
                Button("Delete", role: .destructive) { delete(profile) }
            } message: { profile in
                ServerDeletionMessage(profile: profile)
            }
            .alert(
                "The server was not deleted",
                isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }),
                presenting: deletionError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error.userMessage)
            }
    }

    @ViewBuilder
    private var navigation: some View {
        switch model.navigationStyle {
        case .tabs: tabNavigation
        case .split: splitNavigation
        }
    }

    private var serverActions: ServerActions {
        ServerActions(
            add: { editor = .add },
            edit: { editor = .edit($0) },
            delete: { pendingDeletion = $0 }
        )
    }

    @ViewBuilder
    private var tabNavigation: some View {
        if let profile = model.selectedProfile {
            ServerTabs(profile: profile, actions: serverActions)
        } else {
            FirstRunView(onAdd: { editor = .add })
        }
    }

    private var splitNavigation: some View {
        NavigationSplitView {
            serverList
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } content: {
            Group {
                if let profile = model.selectedProfile {
                    SectionList(profile: profile, onEdit: { editor = .edit(profile) })
                } else {
                    ContentUnavailableView("Choose a server", systemImage: "server.rack")
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            Group {
                if let profile = model.selectedProfile, let section = model.selectedSection {
                    NavigationStack {
                        sectionDetail(section, of: profile)
                    }
                } else {
                    ContentUnavailableView("Choose a section", systemImage: "sidebar.left")
                }
            }
            .navigationSplitViewColumnWidth(min: 520, ideal: 1100)
        }
    }

    private func sectionDetail(_ section: ServerSection, of profile: ServerProfile) -> some View {
        let session = model.session(for: profile)
        return SectionDetail(session: session, section: section)
            .id("\(session.instanceID)-\(section.rawValue)")
    }

    private var autoRefreshTarget: AutoRefreshTarget? {
        guard let profile = model.selectedProfile, let section = model.selectedSection else { return nil }
        return AutoRefreshTarget(session: model.session(for: profile).instanceID, section: section)
    }

    private var providerRefreshLoopID: ProviderRefreshLoopID? {
        guard let profile = model.selectedProfile, profile.authMode == .management else { return nil }
        return ProviderRefreshLoopID(
            session: model.session(for: profile).instanceID,
            enabled: model.refreshesLimitsFromProviders(profile) && model.refreshesAutomatically(profile),
            interval: model.providerRefreshInterval(profile),
            isVisible: isAppVisible
        )
    }

    private var autoRefreshInterval: TimeInterval {
        model.selectedSection == .models ? ServerSection.modelsRefreshInterval : model.refreshInterval
    }

    private func refreshSelection(trigger: RefreshTrigger) async {
        guard let profile = model.selectedProfile, let section = model.selectedSection else { return }
        await model.session(for: profile).refresh(section.refreshScope, trigger: trigger, dropIfCancelled: true)
    }

    private func delete(_ profile: ServerProfile) {
        do {
            try model.delete(profile)
        } catch {
            deletionError = error
        }
    }

    private var serverList: some View {
        List(selection: Binding(
            get: { model.selectedServerID },
            set: { id in
                if let profile = model.profiles.first(where: { $0.id == id }) { model.select(profile) }
            }
        )) {
            serverSection
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add server", systemImage: "plus") { editor = .add }
            }
        }
    }

    private var serverSection: some View {
        Section {
            if model.profiles.isEmpty {
                NoServersRow(onAdd: { editor = .add })
            }
            ForEach(model.profiles) { profile in
                ServerRow(profile: profile, isDefault: profile.id == model.defaultProfile?.id)
                    .tag(profile.id)
                    .serverActions(for: profile, actions: serverActions)
            }
        } footer: {
            Text("The default server feeds the widget and the menu bar.")
        }
    }
}

struct ServerActions {
    let add: () -> Void
    let edit: (ServerProfile) -> Void
    let delete: (ServerProfile) -> Void
}

private struct ServerActionsModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let profile: ServerProfile
    let actions: ServerActions

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Edit", systemImage: "pencil") { actions.edit(profile) }
                Button("Make default", systemImage: "star") { model.makeDefault(profile) }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { actions.delete(profile) }
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) { actions.delete(profile) }
                Button("Edit", systemImage: "pencil") { actions.edit(profile) }
            }
            .swipeActions(edge: .leading) {
                Button("Make default", systemImage: "star") { model.makeDefault(profile) }
                    .tint(.yellow)
            }
    }
}

extension View {
    func serverActions(for profile: ServerProfile, actions: ServerActions) -> some View {
        modifier(ServerActionsModifier(profile: profile, actions: actions))
    }
}

private struct AutoRefreshTarget: Hashable {
    var session: UUID
    var section: ServerSection
}

struct ServerRow: View {
    let profile: ServerProfile
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: profile.isDemo ? "play.rectangle" : "server.rack")
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    DisplayName(profile: profile)
                        .font(.body.weight(.medium))
                    if profile.isDemo { DemoBadge() }
                    if isDefault {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel(Text("Default server"))
                    }
                }
                Text(profile.authMode == .management ? "Management key" : "Client key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !profile.isDemo {
                    Text(verbatim: profile.baseURL.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct SectionList: View {
    @Environment(AppModel.self) private var model
    let profile: ServerProfile
    let onEdit: () -> Void

    var body: some View {
        sectionsList
            .navigationTitle(Text(verbatim: profile.isDemo ? String(localized: "Demo server") : profile.name))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit server", systemImage: "pencil", action: onEdit)
                }
            }
    }

    private var sectionsList: some View {
        List(selection: Binding(get: { model.selectedSection }, set: { model.selectedSection = $0 })) {
            ForEach(model.sections(for: profile)) { section in
                Label { Text(section.title) } icon: { Image(systemName: section.symbol) }
                    .tag(section)
            }
        }
        .safeAreaInset(edge: .bottom) {
            ServerStatus(profile: profile)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ServerStatus: View {
    @Environment(AppModel.self) private var model
    let profile: ServerProfile

    var body: some View {
        let session = model.session(for: profile)
        VStack(alignment: .leading, spacing: 4) {
            if let version = session.version {
                Text("CLIProxyAPI \(version.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            RefreshFooter(lastRefresh: session.lastRefresh, isRefreshing: session.isRefreshing)
                .fixedSize(horizontal: false, vertical: true)
            if !model.refreshesAutomatically(profile) {
                Label("Automatic refresh is off", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SectionDetail: View {
    let session: ServerSession
    let section: ServerSection
    var titledByServer = false

    var body: some View {
        content
            .modifier(SectionTitle(session: session, section: section, titledByServer: titledByServer))
            .refreshable { await session.refresh(section.refreshScope, trigger: .manual) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await session.refresh(section.refreshScope, trigger: .manual) }
                    }
                    .disabled(session.isRefreshing)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .overview: OverviewView(session: session)
        case .accounts: AccountsView(session: session)
        case .usage: UsageView(session: session)
        case .models: ModelsView(session: session)
        case .settings: ServerSettingsView(session: session)
        case .limits: ClientLimitsView(session: session)
        }
    }
}

private struct SectionTitle: ViewModifier {
    let session: ServerSession
    let section: ServerSection
    let titledByServer: Bool

    func body(content: Content) -> some View {
        if section == .overview {
            content
        } else if titledByServer {
            content.modifier(ServerTitle(session: session))
        } else {
            content.navigationTitle(Text(section.title))
        }
    }
}

struct ServerDeletionMessage: View {
    let profile: ServerProfile

    var body: some View {
        if profile.isDemo {
            Text("The demo server is removed from this device. You can add it back from Add server.")
        } else {
            Text("The server and its key are removed from this device. Nothing changes on the server.")
        }
    }
}

private struct NoServersRow: View {
    @Environment(AppModel.self) private var model
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No servers yet")
                .font(.headline)
            Text("Add your CLIProxyAPI server, or bring back the demo server to look around.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add server", systemImage: "plus", action: onAdd)
            Button("Add demo server", systemImage: "play.rectangle") { model.restoreDemo() }
        }
        .padding(.vertical, 6)
    }
}
