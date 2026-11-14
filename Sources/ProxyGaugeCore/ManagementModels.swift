import Foundation

public struct CredentialList: Decodable, Sendable, Equatable {
    public var observedAt: Date?
    public var files: [Credential]
    public var total: Int?
    public var hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case observedAt = "observed_at"
        case files, total
        case hasMore = "has_more"
    }

    public init(observedAt: Date?, files: [Credential], total: Int? = nil, hasMore: Bool? = nil) {
        self.observedAt = observedAt
        self.files = files
        self.total = total
        self.hasMore = hasMore
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = container.lenientDate(.observedAt)
        files = try container.decodeIfPresent([Credential].self, forKey: .files) ?? []
        total = container.lenientInt(.total).map(Int.init)
        hasMore = container.lenientBool(.hasMore)
    }
}

public struct QuotaObservation: Codable, Sendable, Equatable {
    public var signals: [String: String]
    public var observedAt: Date?

    enum CodingKeys: String, CodingKey {
        case signals
        case observedAt = "observed_at"
    }

    public init(signals: [String: String], observedAt: Date?) {
        self.signals = signals
        self.observedAt = observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signals = (try? container.decodeIfPresent([String: String].self, forKey: .signals)) ?? [:]
        observedAt = container.lenientDate(.observedAt)
    }

    public func signal(_ name: String) -> String? {
        if let exact = signals[name] { return exact }
        let lowered = name.lowercased()
        return signals.first { $0.key.lowercased() == lowered }?.value
    }
}

public struct Cooldown: Decodable, Sendable, Equatable, Hashable {
    public var scope: String
    public var modelKey: String?
    public var reason: String
    public var retryAt: Date?
    public var remainingSeconds: Int64?
    public var httpStatus: Int?

    enum CodingKeys: String, CodingKey {
        case scope, reason
        case modelKey = "model_key"
        case retryAt = "retry_at"
        case remainingSeconds = "remaining_seconds"
        case httpStatus = "http_status"
    }

    public init(scope: String, modelKey: String? = nil, reason: String, retryAt: Date?, remainingSeconds: Int64? = nil, httpStatus: Int? = nil) {
        self.scope = scope
        self.modelKey = modelKey
        self.reason = reason
        self.retryAt = retryAt
        self.remainingSeconds = remainingSeconds
        self.httpStatus = httpStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = container.lenientString(.scope) ?? "credential"
        modelKey = container.lenientString(.modelKey)
        reason = container.lenientString(.reason) ?? ""
        retryAt = container.lenientDate(.retryAt)
        remainingSeconds = container.lenientInt(.remainingSeconds)
        httpStatus = container.lenientInt(.httpStatus).map(Int.init)
    }

    public var isCredentialWide: Bool { scope != "model" }

    public func isActive(at now: Date) -> Bool {
        guard let retryAt else { return true }
        return retryAt > now
    }
}

public struct RequestBucket: Decodable, Sendable, Equatable, Hashable {
    public var time: String
    public var success: Int64
    public var failed: Int64

    enum CodingKeys: String, CodingKey { case time, success, failed }

    public init(time: String, success: Int64, failed: Int64) {
        self.time = time
        self.success = success
        self.failed = failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = container.lenientString(.time) ?? ""
        success = container.lenientInt(.success) ?? 0
        failed = container.lenientInt(.failed) ?? 0
    }
}

public struct Credential: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var credentialID: String?
    public var authIndex: String?
    public var provider: String
    public var label: String?
    public var status: String?
    public var statusMessage: String?
    public var disabled: Bool
    public var unavailable: Bool
    public var email: String?
    public var projectID: String?
    public var accountType: String?
    public var success: Int64
    public var failed: Int64
    public var recentRequests: [RequestBucket]
    public var quota: QuotaObservation?
    public var modelQuotas: [String: QuotaObservation]
    public var cooldowns: [Cooldown]?
    public var nextRetryAfter: Date?
    public var lastRefresh: Date?
    public var updatedAt: Date?
    public var priority: Int?
    public var note: String?
    public var requiresSignIn: Bool

    public var id: String { authIndex ?? credentialID ?? name }

    enum CodingKeys: String, CodingKey {
        case id, name, type, provider, label, status, disabled, unavailable, email, success, failed, quota, cooldowns, priority, note
        case authIndex = "auth_index"
        case statusMessage = "status_message"
        case projectID = "project_id"
        case accountType = "account_type"
        case recentRequests = "recent_requests"
        case modelQuotas = "model_quotas"
        case nextRetryAfter = "next_retry_after"
        case lastRefresh = "last_refresh"
        case updatedAt = "updated_at"
        case requiresSignIn = "requires_sign_in"
    }

    public init(
        name: String,
        authIndex: String?,
        provider: String,
        label: String? = nil,
        status: String? = "active",
        disabled: Bool = false,
        unavailable: Bool = false,
        email: String? = nil,
        success: Int64 = 0,
        failed: Int64 = 0,
        recentRequests: [RequestBucket] = [],
        quota: QuotaObservation? = nil,
        modelQuotas: [String: QuotaObservation] = [:],
        cooldowns: [Cooldown]? = []
    ) {
        self.name = name
        self.authIndex = authIndex
        self.provider = provider
        self.label = label
        self.status = status
        self.disabled = disabled
        self.unavailable = unavailable
        self.email = email
        self.success = success
        self.failed = failed
        self.recentRequests = recentRequests
        self.quota = quota
        self.modelQuotas = modelQuotas
        self.cooldowns = cooldowns
        self.requiresSignIn = false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenientString(.name) ?? container.lenientString(.id) ?? ""
        credentialID = container.lenientString(.id)
        authIndex = container.lenientString(.authIndex)
        provider = (container.lenientString(.provider) ?? container.lenientString(.type) ?? "unknown").lowercased()
        label = container.lenientString(.label)
        status = container.lenientString(.status)
        statusMessage = container.lenientString(.statusMessage)
        disabled = container.lenientBool(.disabled) ?? false
        unavailable = container.lenientBool(.unavailable) ?? false
        email = container.lenientString(.email)
        projectID = container.lenientString(.projectID)
        accountType = container.lenientString(.accountType)
        success = container.lenientInt(.success) ?? 0
        failed = container.lenientInt(.failed) ?? 0
        recentRequests = (try? container.decodeIfPresent([RequestBucket].self, forKey: .recentRequests)) ?? []
        quota = try? container.decodeIfPresent(QuotaObservation.self, forKey: .quota)
        modelQuotas = ((try? container.decodeIfPresent([String: QuotaObservation].self, forKey: .modelQuotas)) ?? nil) ?? [:]
        cooldowns = (try? container.decodeIfPresent([Cooldown].self, forKey: .cooldowns)) ?? nil
        nextRetryAfter = container.lenientDate(.nextRetryAfter)
        lastRefresh = container.lenientDate(.lastRefresh)
        updatedAt = container.lenientDate(.updatedAt)
        priority = container.lenientInt(.priority).map(Int.init)
        note = container.lenientString(.note)
        requiresSignIn = container.lenientBool(.requiresSignIn) ?? false
    }

    public var displayName: String {
        for candidate in [email, projectID, label, name] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
        }
        return name
    }

    public var observations: [QuotaObservation] {
        var result: [QuotaObservation] = []
        if let quota, !quota.signals.isEmpty { result.append(quota) }
        for key in modelQuotas.keys.sorted() {
            if let observation = modelQuotas[key], !observation.signals.isEmpty {
                result.append(observation)
            }
        }
        return result
    }
}

public struct StatusUpdateResult: Decodable, Sendable, Equatable {
    public var status: String?
    public var disabled: Bool?
}

public struct CooldownResetResult: Decodable, Sendable, Equatable {
    public var status: String?
    public var authIndex: String?
    public var models: [String]?

    enum CodingKeys: String, CodingKey {
        case status, models
        case authIndex = "auth_index"
    }
}

public struct ConfigWriteResult: Decodable, Sendable, Equatable {
    public var status: String?
    public var configVersion: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case configVersion = "config-version"
    }
}

public struct ProviderKeyCounters: Sendable, Equatable, Identifiable {
    public var provider: String
    public var keyCount: Int
    public var success: Int64
    public var failed: Int64

    public var id: String { provider }

    public init(provider: String, keyCount: Int, success: Int64, failed: Int64) {
        self.provider = provider
        self.keyCount = keyCount
        self.success = success
        self.failed = failed
    }
}

struct APIKeyUsageEntry: Decodable {
    var success: Int64?
    var failed: Int64?
}

enum APIKeyUsageReducer {
    static func reduce(_ data: Data) throws -> [ProviderKeyCounters] {
        let raw = try JSONDecoder().decode([String: [String: APIKeyUsageEntry]].self, from: data)
        return raw.map { provider, entries in
            ProviderKeyCounters(
                provider: provider.lowercased(),
                keyCount: entries.count,
                success: entries.values.reduce(0) { $0 + ($1.success ?? 0) },
                failed: entries.values.reduce(0) { $0 + ($1.failed ?? 0) }
            )
        }
        .sorted { $0.provider < $1.provider }
    }
}

public struct ModelInfo: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var displayName: String?
    public var ownedBy: String?
    public var created: Int64?

    enum CodingKeys: String, CodingKey {
        case id, created
        case displayName = "display_name"
        case ownedBy = "owned_by"
    }

    public init(id: String, displayName: String? = nil, ownedBy: String? = nil, created: Int64? = nil) {
        self.id = id
        self.displayName = displayName
        self.ownedBy = ownedBy
        self.created = created
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = container.lenientString(.displayName)
        ownedBy = container.lenientString(.ownedBy)
        created = container.lenientInt(.created)
    }
}

struct CredentialModelsResponse: Decodable {
    var models: [ModelInfo]?
}

public struct ModelList: Decodable, Sendable, Equatable {
    public var object: String?
    public var data: [ModelInfo]
}

public struct ServerVersion: Sendable, Equatable, Codable {
    public var version: String
    public var commit: String?
    public var buildDate: String?

    public init(version: String, commit: String? = nil, buildDate: String? = nil) {
        self.version = version
        self.commit = commit
        self.buildDate = buildDate
    }

    init?(headers response: HTTPResponse) {
        guard let version = response.header("X-CPA-VERSION"), !version.isEmpty else { return nil }
        self.init(version: version, commit: response.header("X-CPA-COMMIT"), buildDate: response.header("X-CPA-BUILD-DATE"))
    }
}

public struct ClientKeyPolicy: Decodable, Sendable, Equatable {
    public var index: Int?
    public var name: String?
}

public struct RoutingStrategySetting: Sendable, Equatable {
    public static let serverDefault = "round-robin"

    public var strategy: String
    public var isExplicit: Bool
    public var etag: String?

    public init(strategy: String, isExplicit: Bool, etag: String?) {
        self.strategy = strategy
        self.isExplicit = isExplicit
        self.etag = etag
    }
}

enum ConfigNode {
    static let missingNodeError = "not_found"
}
