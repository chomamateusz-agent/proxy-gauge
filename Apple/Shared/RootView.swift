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

    @ViewBuilder
    private var splitNavigation: some View {
        if let profile = model.selectedProfile {
            NavigationSplitView {
                SectionList(profile: profile)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            } detail: {
                let sections = model.sections(for: profile)
                let section = model.selectedSection.flatMap { sections.contains($0) ? $0 : nil } ?? sections[0]
                let session = model.session(for: profile)
                NavigationStack {
                    sectionDetail(section, of: profile, session: session)
                        .modifier(ServerTitleMenu(onAdd: { editor = .add }))
                }
                .id("\(session.instanceID)-\(section.rawValue)-\(model.settingsResetCount)-\(model.deepLinkCount)")
            }
        } else {
            FirstRunView(onAdd: { editor = .add })
        }
    }

    @ViewBuilder
    private func sectionDetail(_ section: ServerSection, of profile: ServerProfile, session: ServerSession) -> some View {
        if section == .settings {
            SettingsPane(profile: profile, session: session, actions: serverActions)
                .modifier(ServerTitle(session: session))
        } else {
            SectionDetail(session: session, section: section, titledByServer: true)
        }
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
        let session = model.session(for: profile)
        if section == .settings {
            await session.refreshSettingsPane(trigger: trigger, dropIfCancelled: true)
        } else {
            await session.refresh(section.refreshScope, trigger: trigger, dropIfCancelled: true)
        }
    }

    private func delete(_ profile: ServerProfile) {
        do {
            try model.delete(profile)
        } catch {
            deletionError = error
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

    var body: some View {
        List(selection: Binding(get: { model.selectedSection }, set: { if let section = $0 { model.selectedSection = section } })) {
            ForEach(model.sections(for: profile)) { section in
                Label { Text(section.tabTitle) } icon: { Image(systemName: section.tabSymbol) }
                    .tag(section)
            }
        }
    }
}

struct SectionDetail: View {
    let session: ServerSession
    let section: ServerSection
    var titledByServer = false

    private var showsFreshnessHeader: Bool {
        #if os(iOS)
        section != .settings
        #else
        true
        #endif
    }

    var body: some View {
        content
            .modifier(SectionTitle(session: session, section: section, titledByServer: titledByServer))
            .refreshable { await session.refresh(section.refreshScope, trigger: .manual) }
            .modifier(SectionRefresh(session: session, scope: section.refreshScope, showsFreshnessHeader: showsFreshnessHeader))
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

private struct SectionRefresh: ViewModifier {
    let session: ServerSession
    let scope: RefreshScope
    let showsFreshnessHeader: Bool

    func body(content: Content) -> some View {
        if showsFreshnessHeader {
            content.freshnessHeader(session: session, scope: scope)
        } else {
            content.toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reload from API", systemImage: "arrow.clockwise") {
                        Task { await session.refresh(scope, trigger: .manual) }
                    }
                    .disabled(session.isRefreshing)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
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
