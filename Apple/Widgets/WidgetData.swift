import AppIntents
import Foundation
import ProxyGaugeCore
import ProxyGaugeStore

enum WidgetData {
    static let store = ProfileStore()

    static let refresher = WidgetSnapshotRefresher(cache: store) { profile in
        let connection = try ServerConnection(profile: profile, secretStore: KeychainSecretStore(), liveTransport: URLSessionTransport(timeout: 12))
        return try await HeadroomLoader.load(profile: profile, secret: connection.secret, transport: connection.transport)
    }

    static func profile(_ serverID: UUID?) -> ServerProfile {
        let settings = store.load()
        return settings.allProfiles.first { $0.id == serverID } ?? settings.defaultProfile
    }

    static func overviewLink(_ profile: ServerProfile) -> URL? {
        SharedConfiguration.urlScheme.flatMap { DeepLink.serverOverview(profile.id).url(scheme: $0) }
    }

    static func timeline<Entry>(for profile: ServerProfile, makeEntry: (Date, WidgetSnapshot) -> Entry) async -> [Entry] {
        let result = await refresher.snapshot(for: profile)
        return WidgetRefreshPolicy.entryDates(for: result.snapshot, from: .now).map { makeEntry($0, result) }
    }
}

struct ServerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Server"
    static let defaultQuery = ServerQuery()

    var id: UUID
    var name: String
    var isDemo: Bool

    init(_ profile: ServerProfile) {
        id = profile.id
        name = profile.name
        isDemo = profile.isDemo
    }

    var displayRepresentation: DisplayRepresentation {
        isDemo ? DisplayRepresentation(title: "Demo server") : DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

struct ServerQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ServerEntity] {
        WidgetData.store.load().allProfiles.filter { identifiers.contains($0.id) }.map(ServerEntity.init)
    }

    func suggestedEntities() async throws -> [ServerEntity] {
        WidgetData.store.load().allProfiles.map(ServerEntity.init)
    }
}

struct ProviderEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static let defaultQuery = ProviderQuery()

    var id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: ProviderCatalog.displayName(id)))
    }
}

struct ProviderQuery: EntityQuery {
    static let commonProviders = ["claude", "codex"]

    func entities(for identifiers: [String]) async throws -> [ProviderEntity] {
        identifiers.map(ProviderEntity.init)
    }

    func suggestedEntities() async throws -> [ProviderEntity] {
        Set(WidgetData.store.cachedProviders() + Self.commonProviders)
            .sorted { ProviderCatalog.displayName($0) < ProviderCatalog.displayName($1) }
            .map(ProviderEntity.init)
    }
}
