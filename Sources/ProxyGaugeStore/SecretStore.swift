import Foundation
import Security

public protocol SecretStore: Sendable {
    func secret(for serverID: UUID) throws -> String?
    func setSecret(_ secret: String, for serverID: UUID) throws
    func deleteSecret(for serverID: UUID) throws
}

public enum SecretStoreError: Error, Equatable, CustomStringConvertible {
    public enum Operation: Sendable {
        case read
        case save
        case delete
    }

    case keychain(OSStatus, Operation)
    case invalidData

    public var operation: Operation {
        switch self {
        case .keychain(_, let operation): operation
        case .invalidData: .read
        }
    }

    public var description: String {
        switch self {
        case .keychain(let status, _): "Keychain status \(status)"
        case .invalidData: "Keychain item is not text"
        }
    }
}

public struct KeychainSecretStore: SecretStore {
    public static let service = "pl.coderoad.proxygauge.server-key"

    struct Location: Hashable {
        var accessGroup: String?
        var dataProtection: Bool
    }

    private let locations: [Location]

    public init(accessGroup: String? = SharedConfiguration.keychainAccessGroup) {
        var candidates = [Location(accessGroup: accessGroup, dataProtection: true)]
        if accessGroup != nil {
            candidates.append(Location(accessGroup: nil, dataProtection: true))
        }
        #if os(macOS)
        candidates.append(Location(accessGroup: nil, dataProtection: false))
        #endif
        locations = candidates
    }

    public func secret(for serverID: UUID) throws -> String? {
        for location in locations {
            var query = baseQuery(serverID, location)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else { throw SecretStoreError.invalidData }
                return secret
            case errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                throw SecretStoreError.keychain(status, .read)
            }
        }
        return nil
    }

    public func setSecret(_ secret: String, for serverID: UUID) throws {
        var lastStatus = errSecMissingEntitlement
        for location in locations {
            lastStatus = upsert(Data(secret.utf8), serverID, location)
            if lastStatus == errSecSuccess { return }
            if lastStatus != errSecMissingEntitlement { break }
        }
        throw SecretStoreError.keychain(lastStatus, .save)
    }

    public func deleteSecret(for serverID: UUID) throws {
        for location in locations {
            let status = SecItemDelete(baseQuery(serverID, location) as CFDictionary)
            guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) else {
                throw SecretStoreError.keychain(status, .delete)
            }
        }
    }

    private func upsert(_ data: Data, _ serverID: UUID, _ location: Location) -> OSStatus {
        let query = baseQuery(serverID, location)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }

    private func baseQuery(_ serverID: UUID, _ location: Location) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: serverID.uuidString,
            kSecUseDataProtectionKeychain as String: location.dataProtection
        ]
        if let group = location.accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [UUID: String] = [:]

    public init() {}

    public func secret(for serverID: UUID) throws -> String? {
        lock.withLock { secrets[serverID] }
    }

    public func setSecret(_ secret: String, for serverID: UUID) throws {
        lock.withLock { secrets[serverID] = secret }
    }

    public func deleteSecret(for serverID: UUID) throws {
        _ = lock.withLock { secrets.removeValue(forKey: serverID) }
    }
}
