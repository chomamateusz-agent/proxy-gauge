import Foundation

public struct AccountList: Sendable {
    public var credentials: Versioned<CredentialList>
    public var keyCounters: Result<[ProviderKeyCounters], APIError>
    public var routerSettings: RouterSettings?
}

public enum ScopeData: Sendable {
    case accounts(AccountList)
    case tokenUsage(ClientKeyUsageReport?)
    case catalog(ModelCatalog)
    case settings(RoutingStrategySetting?, clientKeyCount: Int?)
    case clientModels([ModelInfo])
    case fleetLimits(FleetLimits?)
    case accountModels(name: String, [ModelInfo])
    case routerSettings(RouterSettings)
}

public enum ScopeLoader {
    public typealias Publish = @Sendable (ScopeData) async -> Void

    public static let usageWindow: TimeInterval = 7 * 86_400

    public static func load(_ scope: RefreshScope, authMode: AuthMode, management: ManagementClient, client: ClientKeyClient, readsRouterSettings: Bool = true, now: Date = Date(), onCredentialsReceived: @Sendable () async -> Void = {}, publish: Publish) async throws {
        switch (authMode, scope) {
        case (.management, .accounts), (.management, .limits), (.management, .accountDetail):
            await publish(.accounts(try await accounts(management, readsRouterSettings: readsRouterSettings, onCredentialsReceived: onCredentialsReceived)))
        case (.management, .usage):
            await publish(.accounts(try await accounts(management, readsRouterSettings: readsRouterSettings, onCredentialsReceived: onCredentialsReceived)))
            await publish(.tokenUsage(try await management.clientKeyUsage(since: now.addingTimeInterval(-usageWindow))))
        case (.management, .models):
            let list = try await accounts(management, readsRouterSettings: readsRouterSettings, onCredentialsReceived: onCredentialsReceived)
            await publish(.accounts(list))
            await publish(.catalog(try await ModelCatalog.load(from: management, credentials: list.credentials.value.files)))
        case (.management, .settings):
            let routing = try await management.routingStrategy()
            await publish(.settings(routing, clientKeyCount: try await optional { try await management.clientKeyPolicyCount() } ?? nil))
            if readsRouterSettings, let settings = try await optional({ try await management.routerSettings(strategy: routing?.strategy) }) {
                await publish(.routerSettings(settings))
            }
        case (.management, .accountModels(let name)):
            await publish(.accountModels(name: name, try await management.credentialModels(name: name)))
        case (.clientKey, .models):
            await publish(.clientModels(try await client.models().sorted { $0.id < $1.id }))
        case (.clientKey, .accountModels(let name)):
            await publish(.accountModels(name: name, []))
        case (.clientKey, _):
            await publish(.fleetLimits(try await client.fleetLimits()))
        }
    }

    public static func accounts(_ management: ManagementClient, readsRouterSettings: Bool = true, onCredentialsReceived: @Sendable () async -> Void = {}) async throws -> AccountList {
        let credentials = try await management.credentials()
        await onCredentialsReceived()
        var list: AccountList
        do {
            list = AccountList(credentials: credentials, keyCounters: .success(try await management.upstreamKeyCounters()))
        } catch let error as APIError where !error.stopsFurtherRequests {
            list = AccountList(credentials: credentials, keyCounters: .failure(error))
        }
        if readsRouterSettings, credentials.version?.isFleetFork == true {
            list.routerSettings = try await optional { try await management.routerSettings() } ?? nil
        }
        return list
    }

    private static func optional<Value>(_ read: () async throws -> Value) async throws -> Value? {
        do {
            return try await read()
        } catch let error as APIError where !error.stopsFurtherRequests {
            return nil
        }
    }
}
