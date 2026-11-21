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
            SettingsTab(profile: profile, session: session, actions: actions)
        } else if isFirst {
            SectionDetail(session: session, section: section, titledByServer: true)
                .modifier(ServerTitleMenu())
        } else {
            SectionDetail(session: session, section: section)
        }
    }
}

private struct ServerTitleMenu: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if model.profiles.count > 1 {
            content.toolbarTitleMenu {
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
                Button("Manage servers", systemImage: "gearshape") { model.manageServers() }
            }
        } else {
            content
        }
    }
}

private struct SettingsTab: View {
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
        List {
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
                Button("Edit server", systemImage: "pencil") { actions.edit(profile) }
            } header: {
                DisplayName(profile: profile)
            }
            if session.supportsRouterOrder {
                LabSection(session: session, routerOrder: routerOrder.binding)
            }
            Section {
                NavigationLink {
                    AppSettingsView(title: "App settings")
                } label: {
                    Label("App settings", systemImage: "gearshape")
                }
            }
        }
        .navigationTitle(Text("Settings"))
        .refreshable { await session.refresh(ServerSection.settings.refreshScope, trigger: .manual) }
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
