import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var editor: EditorTarget?
    @State private var showingAppSettings = false
    @State private var pendingDeletion: ServerProfile?
    @State private var deletionError: Error?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        navigation
            .autoRefresh(every: autoRefreshInterval, target: autoRefreshTarget) {
                await refreshSelection(trigger: .automatic)
            }
        #if os(iOS)
            .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
                model.adopt(sizeClass == .compact ? .stack : .split)
            }
        #endif
            .sheet(item: $editor) { target in
                ServerEditor(target: target)
            }
            .sheet(isPresented: $showingAppSettings) {
                NavigationStack {
                    AppSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingAppSettings = false }
                            }
                        }
                }
            }
            .confirmationDialog(
                "Delete this server?",
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { profile in
                Button("Delete", role: .destructive) { delete(profile) }
            } message: { _ in
                Text("The server and its key are removed from this device. Nothing changes on the server.")
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

    private var usesStackNavigation: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    @ViewBuilder
    private var navigation: some View {
        if usesStackNavigation {
            stackNavigation
        } else {
            splitNavigation
        }
    }

    private var splitNavigation: some View {
        NavigationSplitView {
            serverList
        } content: {
            if let profile = model.selectedProfile {
                SectionList(profile: profile, pushesSections: false, onEdit: { editor = .edit(profile) })
            } else {
                ContentUnavailableView("Choose a server", systemImage: "server.rack")
            }
        } detail: {
            if let profile = model.selectedProfile, let section = model.selectedSection {
                NavigationStack {
                    sectionDetail(section, of: profile)
                }
            } else {
                ContentUnavailableView("Choose a section", systemImage: "sidebar.left")
            }
        }
    }

    private var stackNavigation: some View {
        NavigationStack(path: Binding(get: { model.stackPath }, set: { model.stackPath = $0 })) {
            serverList
                .navigationDestination(for: StackRoute.self) { route in
                    stackDestination(route)
                }
        }
    }

    @ViewBuilder
    private func stackDestination(_ route: StackRoute) -> some View {
        switch route {
        case .server(let id):
            if let profile = model.profiles.first(where: { $0.id == id }) {
                SectionList(profile: profile, pushesSections: true, onEdit: { editor = .edit(profile) })
            }
        case .section(let section):
            if let profile = model.selectedProfile {
                sectionDetail(section, of: profile)
            }
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
        Group {
            if usesStackNavigation {
                List { serverSection }
            } else {
                List(selection: Binding(
                    get: { model.selectedServerID },
                    set: { id in
                        if let profile = model.profiles.first(where: { $0.id == id }) { model.select(profile) }
                    }
                )) {
                    serverSection
                }
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add server", systemImage: "plus") { editor = .add }
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { showingAppSettings = true }
            }
            #endif
        }
    }

    private var serverSection: some View {
        Section {
            ForEach(model.profiles) { profile in
                serverRow(profile)
                    .contextMenu { actions(for: profile) }
                    .swipeActions(edge: .trailing) {
                        if !profile.isDemo {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = profile }
                        }
                        Button("Edit", systemImage: "pencil") { editor = .edit(profile) }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Make default", systemImage: "star") { model.makeDefault(profile) }
                            .tint(.yellow)
                    }
            }
        } footer: {
            Text("The default server feeds the widget and the menu bar.")
        }
    }

    @ViewBuilder
    private func serverRow(_ profile: ServerProfile) -> some View {
        let row = ServerRow(profile: profile, isDefault: profile.id == model.defaultProfile.id)
        if usesStackNavigation {
            NavigationLink(value: StackRoute.server(profile.id)) { row }
        } else {
            row.tag(profile.id)
        }
    }

    @ViewBuilder
    private func actions(for profile: ServerProfile) -> some View {
        Button("Edit", systemImage: "pencil") { editor = .edit(profile) }
        Button("Make default", systemImage: "star") { model.makeDefault(profile) }
        if !profile.isDemo {
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = profile }
        }
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
                        .lineLimit(1)
                }
            }
        }
    }
}

struct SectionList: View {
    @Environment(AppModel.self) private var model
    let profile: ServerProfile
    let pushesSections: Bool
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

    @ViewBuilder
    private var sectionsList: some View {
        if pushesSections {
            List { sections }
        } else {
            List(selection: Binding(get: { model.selectedSection }, set: { model.selectedSection = $0 })) {
                sections
            }
        }
    }

    private var sections: some View {
        let session = model.session(for: profile)
        return Section {
            ForEach(ServerSection.sections(for: profile.authMode)) { section in
                sectionRow(section)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let version = session.version {
                    Text("CLIProxyAPI \(version.version)")
                }
                RefreshFooter(lastRefresh: session.lastRefresh, isRefreshing: session.isRefreshing)
            }
        }
    }

    @ViewBuilder
    private func sectionRow(_ section: ServerSection) -> some View {
        let label = Label { Text(section.title) } icon: { Image(systemName: section.symbol) }
        if pushesSections {
            NavigationLink(value: StackRoute.section(section)) { label }
        } else {
            label.tag(section)
        }
    }
}

struct SectionDetail: View {
    let session: ServerSession
    let section: ServerSection

    var body: some View {
        content
            .navigationTitle(Text(section.title))
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
