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
        case .clientKey: [.limits, .models]
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

@MainActor
@Observable
final class AppModel {
    private let store: ProfileStore
    let secrets: any SecretStore
    @ObservationIgnored private var sessions: [UUID: ServerSession] = [:]

    private(set) var settings: StoredSettings
    var selectedServerID: UUID?
    var selectedSection: ServerSection?
    // A collapsed split view keeps a list's selection after going back, so the lists clear it when shown again or tapping the same row would not navigate.
    var usesCollapsedNavigation = false

    init(store: ProfileStore = ProfileStore(), secrets: any SecretStore = KeychainSecretStore()) {
        self.store = store
        self.secrets = secrets
        let loaded = store.load()
        settings = loaded
        selectedServerID = loaded.defaultProfile.id
        selectedSection = ServerSection.sections(for: loaded.defaultProfile.authMode).first
    }

    var profiles: [ServerProfile] { settings.allProfiles }

    var defaultProfile: ServerProfile { settings.defaultProfile }

    var selectedProfile: ServerProfile? {
        profiles.first { $0.id == selectedServerID }
    }

    var refreshInterval: TimeInterval { settings.clampedRefreshInterval }

    func session(for profile: ServerProfile) -> ServerSession {
        if let existing = sessions[profile.id] {
            if existing.profile == profile { return existing }
            existing.retire()
        }
        let session = ServerSession(profile: profile, secrets: secrets, latchStore: store)
        session.onHeadroomUpdate = { [weak self] snapshot in self?.publish(snapshot) }
        sessions[profile.id] = session
        return session
    }

    func select(_ profile: ServerProfile) {
        selectedServerID = profile.id
        selectedSection = usesCollapsedNavigation ? nil : ServerSection.sections(for: profile.authMode).first
    }

    func save(_ profile: ServerProfile, secret: String?, pausedBy pauseReason: AuthPauseReason? = nil) throws {
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
                }
            }
        }
        retireSession(for: profile.id, pausedBy: profile.isDemo ? nil : pauseReason)
        persist()
        if selectedServerID == profile.id {
            select(profile)
        }
    }

    func delete(_ profile: ServerProfile) throws {
        guard !profile.isDemo else { return }
        try secrets.deleteSecret(for: profile.id)
        retireSession(for: profile.id)
        settings.profiles.removeAll { $0.id == profile.id }
        if settings.defaultServerID == profile.id {
            settings.defaultServerID = settings.profiles.first?.id
        }
        if selectedServerID == profile.id {
            select(defaultProfile)
        }
        persist()
    }

    func makeDefault(_ profile: ServerProfile) {
        settings.defaultServerID = profile.id
        persist()
        Task { await refreshDefaultHeadroom(trigger: .automatic) }
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        settings.refreshInterval = interval
        persist()
    }

    func refreshDefaultHeadroom(trigger: RefreshTrigger) async {
        let defaultSession = session(for: defaultProfile)
        await defaultSession.refresh(defaultSession.headroomScope, trigger: trigger, dropIfCancelled: true)
    }

    private func retireSession(for serverID: UUID, pausedBy pauseReason: AuthPauseReason? = nil) {
        store.resetAuthFailureLatch(for: serverID, pausedBy: pauseReason)
        sessions.removeValue(forKey: serverID)?.retire()
    }

    private func persist() {
        store.save(settings)
        reloadWidgets()
    }

    private func publish(_ snapshot: HeadroomSnapshot) {
        guard snapshot.serverID == defaultProfile.id else { return }
        store.saveSnapshot(snapshot)
        reloadWidgets()
    }

    private func reloadWidgets() {
        #if os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
