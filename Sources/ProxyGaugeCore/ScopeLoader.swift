import Foundation

public struct AccountList: Sendable {
    public var credentials: Versioned<CredentialList>
    public var keyCounters: Result<[ProviderKeyCounters], APIError>
}

public enum ScopeData: Sendable {
    case accounts(AccountList)
    case usage(AccountList, ClientKeyUsageReport?)
    case models(AccountList, ModelCatalog)
    case settings(RoutingStrategySetting?, clientKeyCount: Int?)
    case clientModels([ModelInfo])
    case fleetLimits(FleetLimits?)
    case accountModels(name: String, [ModelInfo])
}

public enum ScopeLoader {
    public static let usageWindow: TimeInterval = 7 * 86_400

    public static func load(_ scope: RefreshScope, authMode: AuthMode, management: ManagementClient, client: ClientKeyClient, now: Date = Date()) async throws -> ScopeData {
        switch (authMode, scope) {
        case (.management, .accounts), (.management, .limits):
            return .accounts(try await accounts(management))
        case (.management, .usage):
            let list = try await accounts(management)
            return .usage(list, try await management.clientKeyUsage(since: now.addingTimeInterval(-usageWindow)))
        case (.management, .models):
            let list = try await accounts(management)
            return .models(list, try await ModelCatalog.load(from: management, credentials: list.credentials.value.files))
        case (.management, .settings):
            let routing = try await management.routingStrategy()
            return .settings(routing, clientKeyCount: try await optional { try await management.clientKeyPolicyCount() } ?? nil)
        case (.management, .accountModels(let name)):
            return .accountModels(name: name, try await management.credentialModels(name: name))
        case (.clientKey, .models):
            return .clientModels(try await client.models().sorted { $0.id < $1.id })
        case (.clientKey, .accountModels(let name)):
            return .accountModels(name: name, [])
        case (.clientKey, _):
            return .fleetLimits(try await client.fleetLimits())
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
