import Foundation
import Observation
import ProxyGaugeCore
import ProxyGaugeSession
import ProxyGaugeStore
#if canImport(WidgetKit)
import WidgetKit
#endif

enum ServerSection: String, Hashable, CaseIterable, Identifiable {
    case overview
    case accounts
    case usage
    case models
    case settings
    case limits

    var id: String { rawValue }

    static func sections(for mode: AuthMode) -> [ServerSection] {
        switch mode {
        case .management: [.overview, .accounts, .usage, .models, .settings]
        case .clientKey: [.limits, .models, .settings]
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .overview: "Overview"
        case .accounts: "Accounts"
        case .usage: "Usage"
        case .models: "Models"
        case .settings: "Server settings"
        case .limits: "Limits"
        }
    }

    var tabTitle: LocalizedStringResource {
        self == .settings ? "Settings" : title
    }

    var tabSymbol: String {
        self == .settings ? "gearshape" : symbol
    }

    static let modelsRefreshInterval: TimeInterval = 900

    var refreshScope: RefreshScope {
        switch self {
        case .overview, .accounts: .accounts
        case .usage: .usage
        case .models: .models
        case .settings: .settings
        case .limits: .limits
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .accounts: "person.2"
        case .usage: "chart.bar.xaxis"
        case .models: "cpu"
        case .settings: "slider.horizontal.3"
        case .limits: "speedometer"
        }
    }
}

enum NavigationStyle {
    case split
    case tabs

    static var platform: NavigationStyle {
        #if os(iOS)
        .tabs
        #else
        .split
        #endif
    }
}

@MainActor
@Observable
final class AppModel {
    private let store: ProfileStore
    let secrets: any SecretStore
    @ObservationIgnored private let providerRefresh: ActiveRefreshCoordinator
    @ObservationIgnored private var sessions: [UUID: ServerSession] = [:]

    private(set) var settings: StoredSettings
    var selectedServerID: UUID?
    var selectedSection: ServerSection?
    let navigationStyle = NavigationStyle.platform
    private(set) var deepLinkCount = 0
    private(set) var settingsResetCount = 0

    init(store: ProfileStore = ProfileStore(), secrets: any SecretStore = KeychainSecretStore()) {
        self.store = store
        self.secrets = secrets
        providerRefresh = ActiveRefreshCoordinator(store: store)
        store.discardPreviousActiveQuotas()
        let loaded = store.load()
        settings = loaded
        selectedServerID = loaded.defaultProfile?.id
        selectedSection = loaded.defaultProfile.flatMap { ServerSection.sections(for: $0.authMode).first }
    }

    var profiles: [ServerProfile] { settings.allProfiles }

    var defaultProfile: ServerProfile? { settings.defaultProfile }

    var showsDemo: Bool { settings.showsDemo }

    var selectedProfile: ServerProfile? {
        profiles.first { $0.id == selectedServerID }
    }

    var refreshInterval: TimeInterval { settings.clampedRefreshInterval }

    func refreshesAutomatically(_ profile: ServerProfile) -> Bool {
        settings.refreshesAutomatically(profile.id)
    }

    func setRefreshesAutomatically(_ enabled: Bool, for profile: ServerProfile) {
        settings.setRefreshesAutomatically(enabled, for: profile.id)
        sessions[profile.id]?.refreshesAutomatically = enabled
        persist()
    }

    func refreshesLimitsFromProviders(_ profile: ServerProfile) -> Bool {
        settings.refreshesLimitsFromProviders(profile.id)
    }

    func setRefreshesLimitsFromProviders(_ enabled: Bool, for profile: ServerProfile) {
        settings.setRefreshesLimitsFromProviders(enabled, for: profile.id)
        sessions[profile.id]?.refreshesLimitsAutomatically = enabled
        persist()
    }

    func providerRefreshInterval(_ profile: ServerProfile) -> TimeInterval {
        settings.providerRefreshInterval(profile.id)
    }

    func setProviderRefreshInterval(_ interval: TimeInterval, for profile: ServerProfile) {
        settings.setProviderRefreshInterval(interval, for: profile.id)
        sessions[profile.id]?.providerRefreshInterval = interval
        persist()
    }

    func session(for profile: ServerProfile) -> ServerSession {
        if let existing = sessions[profile.id] {
            if existing.profile == profile { return existing }
            existing.retire()
        }
        let session = ServerSession(
            profile: profile,
            secrets: secrets,
            latchStore: store,
            refreshesAutomatically: refreshesAutomatically(profile),
            coordinator: providerRefresh,
            refreshesLimitsAutomatically: refreshesLimitsFromProviders(profile),
            providerRefreshInterval: providerRefreshInterval(profile)
        )
        session.onHeadroomUpdate = { [weak self] snapshot in self?.publish(snapshot) }
        sessions[profile.id] = session
        return session
    }

    func sections(for profile: ServerProfile) -> [ServerSection] {
        ServerSection.sections(for: profile.authMode)
    }

    func select(_ profile: ServerProfile) {
        selectedServerID = profile.id
        selectedSection = SectionAfterSwitch.section(
            current: selectedSection,
            available: sections(for: profile),
            keepsCurrent: true
        )
    }

    func manageServers() {
        selectedSection = .settings
        settingsResetCount += 1
    }

    func open(_ url: URL) {
        guard let scheme = SharedConfiguration.urlScheme,
              case .serverOverview(let id)? = DeepLink(url: url, scheme: scheme),
              let profile = profiles.first(where: { $0.id == id })
        else { return }
        selectedServerID = profile.id
        selectedSection = sections(for: profile).first
        deepLinkCount += 1
    }

    func save(_ profile: ServerProfile, secret: String?, pausedBy pauseReason: AuthPauseReason? = nil) throws {
        let previous = settings.profiles.first { $0.id == profile.id }
        var becameDefault = false
        let keepsData = previous.map { $0.reachesSameData(as: profile) } == true && !changesKey(of: profile.id, to: secret)
        if profile.isDemo {
            settings.demoAuthMode = profile.authMode
        } else {
            if let secret, !secret.isEmpty {
                try secrets.setSecret(secret, for: profile.id)
            }
            if let index = settings.profiles.firstIndex(where: { $0.id == profile.id }) {
                settings.profiles[index] = profile
            } else {
                settings.profiles.append(profile)
                if settings.profiles.count == 1 {
                    settings.defaultServerID = profile.id
                    becameDefault = true
                }
            }
        }
        retireSession(for: profile.id, pausedBy: profile.isDemo ? nil : pauseReason, keepingSnapshotNamed: keepsData ? profile.name : nil)
        if let previous, !keepsData {
            forgetProviderReadingsIfUnused(previous)
        }
        persist()
        let selection = SelectionAfterSave(
            saving: profile.id,
            selected: selectedServerID,
            selectionExists: selectedProfile != nil,
            savedBecameDefault: becameDefault
        )
        if selection == .select {
            select(profile)
        }
    }

    private func changesKey(of serverID: UUID, to secret: String?) -> Bool {
        guard let secret, !secret.isEmpty else { return false }
        return (try? secrets.secret(for: serverID)) != secret
    }

    private func forgetProviderReadingsIfUnused(_ profile: ServerProfile) {
        let proxy = ActiveRefreshServer.proxyKey(profile.baseURL)
        let stillUsed = settings.allProfiles.contains { $0.id != profile.id && ActiveRefreshServer.proxyKey($0.baseURL) == proxy }
        if !stillUsed { store.forgetActiveQuotas(proxy: proxy) }
    }

    func delete(_ profile: ServerProfile) throws {
        if profile.isDemo {
            Task { await DemoTransport.shared.reset() }
        } else {
            try secrets.deleteSecret(for: profile.id)
        }
        store.forgetServer(profile.id)
        sessions.removeValue(forKey: profile.id)?.retire()
        settings.removeServer(profile.id)
        forgetProviderReadingsIfUnused(profile)
        applySelection(SelectionAfterRemoval(
            removing: profile.id,
            selected: selectedServerID,
            fallback: defaultProfile?.id
        ))
        persist()
    }

    func restoreDemo() {
        settings.restoreDemo()
        persist()
        if selectedProfile == nil {
            select(settings.demoProfile)
        }
    }

    private func applySelection(_ selection: SelectionAfterRemoval) {
        guard selection != .keep else { return }
        if case .select(let id) = selection, let profile = profiles.first(where: { $0.id == id }) {
            select(profile)
        } else {
            selectedServerID = nil
            selectedSection = nil
        }
    }

    func makeDefault(_ profile: ServerProfile) {
        settings.defaultServerID = profile.id
        persist()
        guard refreshesAutomatically(profile) else { return }
        Task { await refreshDefaultHeadroom(trigger: .automatic) }
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        settings.refreshInterval = interval
        persist()
    }

    func refreshDefaultHeadroom(trigger: RefreshTrigger) async {
        guard let defaultProfile else { return }
        let defaultSession = session(for: defaultProfile)
        await defaultSession.refresh(defaultSession.headroomScope, trigger: trigger, dropIfCancelled: true)
    }

    private func retireSession(for serverID: UUID, pausedBy pauseReason: AuthPauseReason?, keepingSnapshotNamed name: String?) {
        store.resetAuthFailureLatch(for: serverID, pausedBy: pauseReason, keepingSnapshotNamed: name)
        if name == nil {
            store.forgetSnapshot(for: serverID)
        }
        sessions.removeValue(forKey: serverID)?.retire()
    }

    private func persist() {
        store.save(settings)
        reloadWidgets()
    }

    private func publish(_ snapshot: HeadroomSnapshot) {
        store.saveSnapshot(snapshot)
        reloadWidgets()
    }

    private func reloadWidgets() {
        #if os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
