import Foundation

public struct AccountList: Sendable {
    public var credentials: Versioned<CredentialList>
    public var keyCounters: Result<[ProviderKeyCounters], APIError>
}

public enum ScopeData: Sendable {
    case accounts(AccountList)
    case tokenUsage(ClientKeyUsageReport?)
    case catalog(ModelCatalog)
    case settings(RoutingStrategySetting?, clientKeyCount: Int?)
    case clientModels([ModelInfo])
    case fleetLimits(FleetLimits?)
    case accountModels(name: String, [ModelInfo])
}

public enum ScopeLoader {
    public typealias Publish = @Sendable (ScopeData) async -> Void

    public static let usageWindow: TimeInterval = 7 * 86_400

    public static func load(_ scope: RefreshScope, authMode: AuthMode, management: ManagementClient, client: ClientKeyClient, now: Date = Date(), publish: Publish) async throws {
        switch (authMode, scope) {
        case (.management, .accounts), (.management, .limits):
            await publish(.accounts(try await accounts(management)))
        case (.management, .usage):
            await publish(.accounts(try await accounts(management)))
            await publish(.tokenUsage(try await management.clientKeyUsage(since: now.addingTimeInterval(-usageWindow))))
        case (.management, .models):
            let list = try await accounts(management)
            await publish(.accounts(list))
            await publish(.catalog(try await ModelCatalog.load(from: management, credentials: list.credentials.value.files)))
        case (.management, .settings):
            let routing = try await management.routingStrategy()
            await publish(.settings(routing, clientKeyCount: try await optional { try await management.clientKeyPolicyCount() } ?? nil))
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

    public static func accounts(_ management: ManagementClient) async throws -> AccountList {
        let credentials = try await management.credentials()
        do {
            return AccountList(credentials: credentials, keyCounters: .success(try await management.upstreamKeyCounters()))
        } catch let error as APIError where !error.isAuthenticationFailure {
            return AccountList(credentials: credentials, keyCounters: .failure(error))
        }
    }

    private static func optional<Value>(_ read: () async throws -> Value) async throws -> Value? {
        do {
            return try await read()
        } catch let error as APIError where !error.isAuthenticationFailure {
            return nil
        }
    }
}
