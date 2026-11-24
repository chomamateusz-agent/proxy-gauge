import AppKit
import ProxyGaugeCore
import ProxyGaugeSession
import ProxyGaugeStore
import SwiftUI

@MainActor
enum MacRedesignRenders {
    static let sizes: [(name: String, size: CGSize)] = [("1440x900", CGSize(width: 1440, height: 900)), ("1100x800", CGSize(width: 1100, height: 800))]
    static let appearances: [(name: String, appearance: NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    static let labSuiteName = "proxygauge.render-tool.lab"

    static func run(model: AppModel, defaults: UserDefaults, output: URL) async throws {
        guard let demoProfile = model.defaultProfile else { return }
        let demo = model.session(for: demoProfile)
        for scope in [RefreshScope.usage, .models, .settings] {
            await demo.refresh(scope, trigger: .manual)
        }
        defaults.set(OverviewLayout.compactRows.rawValue, forKey: OverviewLayout.storageKey)
        defer { defaults.removeObject(forKey: OverviewLayout.storageKey) }
        if Renderer.rendersPolish {
            try await renderPolish(model: model, defaults: defaults, demo: demo, output: output)
            return
        }
        let lab = try await labServer()
        defer { UserDefaults.standard.removePersistentDomain(forName: labSuiteName) }
        let cooling = ServerSession(
            profile: ServerProfile(name: "Sample fleet", baseURL: URL(string: "https://render.invalid")!, authMode: .management),
            secrets: MemorySecretStore(),
            latchStore: nil,
            transport: CoolingPoolTransport()
        )
        await cooling.refresh(.accounts, trigger: .manual)
        let clientKey = ServerSession(
            profile: ServerProfile(name: "Sample fleet", baseURL: URL(string: "https://render.invalid")!, authMode: .clientKey),
            secrets: MemorySecretStore(),
            latchStore: nil,
            transport: CoolingPoolTransport()
        )
        await clientKey.refresh(.limits, trigger: .manual)
        let checked = Renderer.providerSession("Provider results", transport: ProviderRenderTransport())
        await checked.refreshLimits(trigger: .manual, origin: .visibleApp)
        for (sizeName, size) in sizes {
            for (scheme, appearance) in appearances {
                func file(_ name: String) -> URL { output.appending(path: "impl-\(name)-\(sizeName)-\(scheme).png") }
                for (name, section) in [("overview", ServerSection.overview), ("accounts", .accounts), ("usage", .usage), ("models", .models), ("settings", .settings)] {
                    model.selectedSection = section
                    try await Renderer.renderWindow(model: model, defaults: defaults, size: size, appearance: appearance, to: file(name))
                }
                model.selectedSection = .overview
                let provider = window(model: model, defaults: defaults, profile: demoProfile) {
                    ProviderDetailView(session: demo, provider: "claude")
                }
                try await Renderer.renderInWindow(provider, size: size, appearance: appearance, to: file("provider-claude"))
                model.selectedSection = .accounts
                if let team = demo.accountSummaries.first(where: { CardStatus(account: $0, now: .now).isBlocked }) {
                    let detail = window(model: model, defaults: defaults, profile: demoProfile) {
                        AccountDetailView(session: demo, credentialID: team.id)
                    }
                    try await Renderer.renderInWindow(detail, size: size, appearance: appearance, to: file("account-detail"))
                }
                lab.model.selectedSection = .settings
                let settings = window(model: lab.model, defaults: lab.defaults, profile: lab.session.profile) {
                    SettingsPane(profile: lab.session.profile, session: lab.session, actions: ServerActions(add: {}, edit: { _ in }, delete: { _ in }))
                        .modifier(ServerTitle(session: lab.session))
                }
                try await Renderer.renderInWindow(settings, size: size, appearance: appearance, to: file("settings-lab-fork"))
                model.selectedSection = .overview
                let pool = window(model: model, defaults: defaults, profile: demoProfile) {
                    OverviewView(session: cooling)
                        .freshnessHeader(session: cooling, scope: .accounts)
                }
                try await Renderer.renderInWindow(pool, size: size, appearance: appearance, to: file("cooling-pool-overview"))
                model.selectedSection = .limits
                let limits = window(model: model, defaults: defaults, profile: clientKey.profile) {
                    ClientLimitsView(session: clientKey)
                        .freshnessHeader(session: clientKey, scope: .limits)
                }
                try await Renderer.renderInWindow(limits, size: size, appearance: appearance, to: file("client-key-limits"))
                model.selectedSection = .accounts
                let sources = window(model: model, defaults: defaults, profile: demoProfile) {
                    AccountDetailView(session: checked, credentialID: "a1f3c9")
                }
                try await Renderer.renderInWindow(sources, size: size, appearance: appearance, to: file("account-detail-provider-sources"))
            }
        }
        try await renderPopovers(sessions: [("demo", demo), ("cooling-pool", cooling)], output: output)
        try await renderLongPopover(output: output)
        for (scheme, appearance) in appearances {
            for (name, source) in [("management", model), ("fork-two-servers", lab.model)] {
                guard let profile = source.selectedProfile else { continue }
                source.selectedSection = nil
                let sidebar = SectionList(profile: profile).environment(source).listStyle(.sidebar)
                try await Renderer.render(sidebar, size: CGSize(width: 210, height: 220), appearance: appearance, to: output.appending(path: "impl-sidebar-\(name)-\(scheme).png"))
            }
        }
    }

    static func renderPolish(model: AppModel, defaults: UserDefaults, demo: ServerSession, output: URL) async throws {
        guard let demoProfile = model.defaultProfile else { return }
        model.selectedSection = .overview
        try await Renderer.renderWindow(model: model, defaults: defaults, size: CGSize(width: 1440, height: 900), appearance: .aqua, to: output.appending(path: "impl-overview-1440x900-light-pl.png"))
        let provider = window(model: model, defaults: defaults, profile: demoProfile) {
            ProviderDetailView(session: demo, provider: "claude")
        }
        try await Renderer.renderInWindow(provider, size: CGSize(width: 1100, height: 800), appearance: .darkAqua, to: output.appending(path: "impl-provider-claude-1100x800-dark-pl.png"))
        try await renderPopovers(sessions: [("demo", demo)], output: output, suffix: "-pl")
    }

    static func renderPopovers(sessions: [(name: String, session: ServerSession)], output: URL, suffix: String = "") async throws {
        let now = Date.now
        for (name, session) in sessions {
            guard let cooling = session.accountSummaries.first(where: { CardStatus(account: $0, now: now).isBlocked && !$0.modelCooldowns.isEmpty })
                ?? session.accountSummaries.first(where: { CardStatus(account: $0, now: now).isBlocked }),
                let idle = session.accountSummaries.first(where: { $0.hasIdleFiveHourWindow(at: now) }) ?? session.accountSummaries.first
            else { continue }
            for (scheme, appearance) in appearances {
                let popover = StatusPopover(account: cooling, session: session, checkNow: {})
                    .fixedSize()
                    .background(BoardStyle.cardBackground)
                try await Renderer.render(popover, size: CGSize(width: 340, height: 520), appearance: appearance, to: output.appending(path: "impl-cooldown-popover-\(name)-\(scheme)\(suffix).png"))
                for (label, account) in [("blocked", cooling), ("idle", idle)] {
                    let resets = ResetsSheet(account: account)
                    try await Renderer.renderInWindow(resets, size: CGSize(width: 460, height: 420), appearance: appearance, to: output.appending(path: "impl-resets-\(label)-\(name)-\(scheme)\(suffix).png"))
                }
            }
        }
    }

    static func renderLongPopover(output: URL) async throws {
        let now = Date.now
        let account = AccountSummary(
            id: "long-popover",
            provider: "claude",
            label: "render-long@example.invalid",
            state: .error,
            plan: "max",
            bars: [],
            statusMessage: String(repeating: "The provider answered with an error while the proxy refreshed this account's sign-in and will retry later. ", count: 7),
            creditsBalance: 12.5,
            modelCooldowns: (1...8).map { ModelCooldown(model: "render-model-\($0)", until: now.addingTimeInterval(Double($0) * 3_600)) }
        )
        for (scheme, appearance) in appearances {
            let popover = StatusPopover(account: account, session: nil, checkNow: {})
                .background(BoardStyle.cardBackground)
            try await Renderer.render(popover, size: CGSize(width: 340, height: 520), appearance: appearance, to: output.appending(path: "impl-cooldown-popover-long-\(scheme).png"))
            let resets = ResetsSheet(account: account)
            try await Renderer.renderInWindow(resets, size: CGSize(width: 460, height: 520), appearance: appearance, to: output.appending(path: "impl-resets-long-\(scheme).png"))
        }
    }

    static func window(model: AppModel, defaults: UserDefaults, profile: ServerProfile, @ViewBuilder detail: () -> some View) -> some View {
        NavigationSplitView {
            SectionList(profile: profile)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            NavigationStack {
                detail()
                    .modifier(ServerTitleMenu(onAdd: {}))
            }
        }
        .toggleStyle(CapturableSwitchStyle())
        .environment(model)
        .defaultAppStorage(defaults)
    }

    static func labServer() async throws -> (model: AppModel, defaults: UserDefaults, session: ServerSession) {
        let defaults = UserDefaults(suiteName: labSuiteName)!
        defaults.removePersistentDomain(forName: labSuiteName)
        let store = ProfileStore(defaults: defaults)
        let fork = ServerProfile(name: "Fork server", baseURL: URL(string: "https://fork.render.invalid")!, authMode: .management)
        var settings = store.load()
        settings.profiles = [fork]
        settings.defaultServerID = fork.id
        store.save(settings)
        let model = AppModel(store: store, secrets: MemorySecretStore())
        let session = ServerSession(profile: fork, secrets: MemorySecretStore(), latchStore: nil, transport: ForkVersionTransport())
        await session.refreshSettingsPane(trigger: .manual)
        return (model, defaults, session)
    }
}
