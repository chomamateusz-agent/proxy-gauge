import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct ServerTabs: View {
    @Environment(AppModel.self) private var model
    let profile: ServerProfile
    let actions: ServerActions

    var body: some View {
        let session = model.session(for: profile)
        let tabs = model.sections(for: profile)
        TabView(selection: Binding(
            get: { model.selectedSection.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs[0] },
            set: { model.selectedSection = $0 }
        )) {
            ForEach(tabs) { section in
                let isFirst = section == tabs.first
                Tab(value: section) {
                    NavigationStack {
                        content(section, session: session, isFirst: isFirst)
                    }
                    .id("\(session.instanceID)-\(section.rawValue)-\(resetCount(section, isFirst: isFirst))")
                } label: {
                    Label { Text(section.tabTitle) } icon: { Image(systemName: section.tabSymbol) }
                }
            }
        }
    }

    private func resetCount(_ section: ServerSection, isFirst: Bool) -> Int {
        if section == .settings { return model.settingsResetCount }
        return isFirst ? model.deepLinkCount : 0
    }

    @ViewBuilder
    private func content(_ section: ServerSection, session: ServerSession, isFirst: Bool) -> some View {
        if section == .settings {
            SettingsPane(profile: profile, session: session, actions: actions)
        } else if isFirst {
            SectionDetail(session: session, section: section, titledByServer: true)
                .modifier(ServerTitleMenu())
        } else {
            SectionDetail(session: session, section: section)
        }
    }
}

struct ServerTitleMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    var onAdd: (() -> Void)?

    func body(content: Content) -> some View {
        if model.profiles.count > 1 {
            #if os(macOS)
            content.toolbar {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        menuItems
                    } label: {
                        Label("Servers", systemImage: "server.rack")
                            .labelStyle(.titleAndIcon)
                    }
                    .help(Text("Switch server"))
                }
            }
            #else
            content.toolbarTitleMenu { menuItems }
            #endif
        } else {
            content
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Picker("Servers", selection: Binding(
            get: { model.selectedServerID },
            set: { id in
                if let profile = model.profiles.first(where: { $0.id == id }) { model.select(profile) }
            }
        )) {
            ForEach(model.profiles) { profile in
                DisplayName(profile: profile)
                    .tag(Optional(profile.id))
            }
        }
        .pickerStyle(.inline)
        if let onAdd {
            Button("Add server…", systemImage: "plus", action: onAdd)
        }
        Button("Manage servers", systemImage: "gearshape") { model.manageServers() }
    }
}

struct SettingsPane: View {
    @Environment(AppModel.self) private var model
    let profile: ServerProfile
    let session: ServerSession
    let actions: ServerActions
    private let routerOrder: RouterOrderStorage

    init(profile: ServerProfile, session: ServerSession, actions: ServerActions) {
        self.profile = profile
        self.session = session
        self.actions = actions
        routerOrder = RouterOrderStorage(serverID: profile.id)
    }

    var body: some View {
        container {
            Section {
                ForEach(model.profiles) { server in
                    Button {
                        model.select(server)
                    } label: {
                        HStack {
                            ServerRow(profile: server, isDefault: server.id == model.defaultProfile?.id)
                            Spacer(minLength: 8)
                            if server.id == profile.id {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(server.id == profile.id ? .isSelected : [])
                    .serverActions(for: server, actions: actions)
                }
                Button("Add server", systemImage: "plus", action: actions.add)
            } header: {
                Text("Servers")
            } footer: {
                Text("The default server feeds the widget and the menu bar.")
            }
            Section {
                #if os(macOS)
                LabeledContent("Address") { Text(verbatim: profile.isDemo ? "–" : profile.baseURL.absoluteString).textSelection(.enabled) }
                LabeledContent("Mode") { Text(profile.authMode == .management ? "Management key" : "Client key") }
                #endif
                ServerFactRows(session: session, includesLastRefresh: false) { title, value in
                    LabeledContent { value } label: { Text(title) }
                }
                AutoRefreshToggle(profile: profile)
                if profile.authMode == .management {
                    NavigationLink {
                        SectionDetail(session: session, section: .settings)
                    } label: {
                        Label("Server settings", systemImage: ServerSection.settings.symbol)
                    }
                }
                #if os(macOS)
                NavigationLink {
                    DashboardFootnotesPage()
                } label: {
                    Label("How these numbers work", systemImage: "info.circle")
                }
                #endif
                Button("Edit server", systemImage: "pencil") { actions.edit(profile) }
            } header: {
                DisplayName(profile: profile)
            }
            if session.supportsRouterOrder {
                LabSection(session: session, routerOrder: routerOrder.binding)
            }
            #if os(macOS)
            AppSettingsSections()
            #else
            Section {
                NavigationLink {
                    AppSettingsView(title: "App settings")
                } label: {
                    Label("App settings", systemImage: "gearshape")
                }
            }
            #endif
        }
        #if os(iOS)
        .navigationTitle(Text("Settings"))
        #endif
        .refreshable { await session.refreshSettingsPane(trigger: .manual) }
        #if os(macOS)
        .freshnessHeader(session: session, scope: ServerSection.settings.refreshScope)
        #endif
    }

    @ViewBuilder
    private func container(@ViewBuilder content: () -> some View) -> some View {
        #if os(macOS)
        Form(content: content).formStyle(.grouped)
        #else
        List(content: content)
        #endif
    }
}

extension ServerSession {
    func refreshSettingsPane(trigger: RefreshTrigger, dropIfCancelled: Bool = false) async {
        if profile.authMode == .management {
            await refresh(.accounts, trigger: trigger, dropIfCancelled: dropIfCancelled)
        }
        await refresh(ServerSection.settings.refreshScope, trigger: trigger, dropIfCancelled: dropIfCancelled)
    }
}

struct FirstRunView: View {
    @Environment(AppModel.self) private var model
    let onAdd: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("No servers yet", systemImage: "server.rack")
            } description: {
                Text("Add your CLIProxyAPI server, or bring back the demo server to look around.")
            } actions: {
                Button("Add server", systemImage: "plus", action: onAdd)
                    .buttonStyle(.borderedProminent)
                Button("Add demo server", systemImage: "play.rectangle") { model.restoreDemo() }
            }
        }
    }
}

struct LabSection: View {
    let session: ServerSession
    @Binding var routerOrder: Bool

    var body: some View {
        Section {
            Toggle("Router order", isOn: $routerOrder)
        } header: {
            Text("Lab")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Account cards and pool bars follow the order in which the proxy picks accounts, like Quota Cards in router order in the fork panel.")
                if routerOrder {
                    if let settings = session.routerSettings {
                        if !settings.ranksByUseOrLose {
                            Text("This server does not route with use-or-lose, so the cards keep the list order.")
                        }
                    } else {
                        Text("Router settings not read yet, so the cards keep the usable-first order.")
                    }
                }
            }
        }
    }
}
