import Foundation

public struct FleetLimits: Decodable, Sendable, Equatable {
    public var object: String
    public var generatedAt: Date?
    public var proxyVersion: String?
    public var clientName: String?
    public var models: [FleetModel]
    public var exclusions: [FleetExclusion]
    public var credentials: [FleetCredential]
    public var summary: [String: FleetProviderSummary]

    enum CodingKeys: String, CodingKey {
        case object, client, models, exclusions, credentials, summary
        case generatedAt = "generated_at"
        case proxyVersion = "proxy_version"
    }

    struct Client: Decodable {
        var name: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = container.lenientString(.object) ?? ""
        generatedAt = container.lenientDate(.generatedAt)
        proxyVersion = container.lenientString(.proxyVersion)
        clientName = (try? container.decodeIfPresent(Client.self, forKey: .client))??.name
        models = try container.decodeIfPresent([FleetModel].self, forKey: .models) ?? []
        exclusions = try container.decodeIfPresent([FleetExclusion].self, forKey: .exclusions) ?? []
        credentials = try container.decodeIfPresent([FleetCredential].self, forKey: .credentials) ?? []
        summary = try container.decodeIfPresent([String: FleetProviderSummary].self, forKey: .summary) ?? [:]
    }
}

public struct FleetModel: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var providers: [String]
}

public struct FleetExclusion: Decodable, Sendable, Equatable, Hashable {
    public var pattern: String
    public var provider: String?
    public var source: String
    public var until: Date?
    public var untilSource: String?

    enum CodingKeys: String, CodingKey {
        case pattern, provider, source, until
        case untilSource = "until_source"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pattern = container.lenientString(.pattern) ?? ""
        provider = container.lenientString(.provider)
        source = container.lenientString(.source) ?? ""
        until = container.lenientDate(.until)
        untilSource = container.lenientString(.untilSource)
    }
}

public struct FleetBar: Decodable, Sendable, Equatable {
    public var id: String
    public var percent: Double?
    public var status: String?
    public var resetsAt: Date?
    public var sampledAt: Date?
    public var resetPassed: Bool

    enum CodingKeys: String, CodingKey {
        case id, percent, status
        case resetsAt = "resets_at"
        case sampledAt = "sampled_at"
        case resetPassed = "reset_passed"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        percent = (try? container.decodeIfPresent(Double.self, forKey: .percent)) ?? nil
        status = container.lenientString(.status)
        resetsAt = container.lenientDate(.resetsAt)
        sampledAt = container.lenientDate(.sampledAt)
        resetPassed = container.lenientBool(.resetPassed) ?? false
    }

    public var quotaBar: QuotaBar {
        QuotaBar(id: id, usedPercent: resetPassed ? 0 : percent, status: status, resetsAt: resetPassed ? nil : resetsAt, sampledAt: sampledAt)
    }
}

public struct FleetCredits: Decodable, Sendable, Equatable {
    public var hasCredits: Bool?
    public var unlimited: Bool?
    public var balance: Double?

    enum CodingKeys: String, CodingKey {
        case unlimited, balance
        case hasCredits = "has_credits"
    }
}

public struct FleetCooldown: Decodable, Sendable, Equatable, Hashable {
    public var scope: String
    public var model: String?
    public var reason: String
    public var until: Date?
    public var httpStatus: Int?

    enum CodingKeys: String, CodingKey {
        case scope, model, reason, until
        case httpStatus = "http_status"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = container.lenientString(.scope) ?? ""
        model = container.lenientString(.model)
        reason = container.lenientString(.reason) ?? ""
        until = container.lenientDate(.until)
        httpStatus = container.lenientInt(.httpStatus).map(Int.init)
    }
}

public struct FleetCredential: Decodable, Sendable, Equatable, Identifiable {
    public var label: String
    public var provider: String
    public var plan: String?
    public var state: String
    public var bars: [FleetBar]
    public var credits: FleetCredits?
    public var cooldowns: [FleetCooldown]

    public var id: String { provider + "/" + label }

    public var credentialState: CredentialState { CredentialState(wireValue: state) }
}

public struct FleetSummaryBar: Decodable, Sendable, Equatable {
    public var percent: Double
    public var resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case percent
        case resetsAt = "resets_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        percent = (try? container.decode(Double.self, forKey: .percent)) ?? 0
        resetsAt = container.lenientDate(.resetsAt)
    }
}

public struct FleetProviderSummary: Decodable, Sendable, Equatable {
    public var usableCredentials: Int
    public var bars: [String: FleetSummaryBar]

    enum CodingKeys: String, CodingKey {
        case bars
        case usableCredentials = "usable_credentials"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usableCredentials = container.lenientInt(.usableCredentials).map(Int.init) ?? 0
        bars = (try? container.decodeIfPresent([String: FleetSummaryBar].self, forKey: .bars)) ?? [:]
    }
}

public struct ClientKeyUsageReport: Decodable, Sendable, Equatable {
    public var generatedAt: Date?
    public var from: Date?
    public var to: Date?
    public var recordingSince: Date?
    public var keys: [ClientKeyUsage]

    enum CodingKeys: String, CodingKey {
        case from, to, keys
        case generatedAt = "generated_at"
        case recordingSince = "recording_since"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = container.lenientDate(.generatedAt)
        from = container.lenientDate(.from)
        to = container.lenientDate(.to)
        recordingSince = container.lenientDate(.recordingSince)
        keys = try container.decodeIfPresent([ClientKeyUsage].self, forKey: .keys) ?? []
    }
}

public struct TokenCounters: Decodable, Sendable, Equatable {
    public var requests: Int64 = 0
    public var failedRequests: Int64 = 0
    public var inputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var reasoningTokens: Int64 = 0
    public var cacheReadTokens: Int64 = 0
    public var cacheCreationTokens: Int64 = 0
    public var totalTokens: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case requests
        case failedRequests = "failed_requests"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case reasoningTokens = "reasoning_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cacheCreationTokens = "cache_creation_tokens"
        case totalTokens = "total_tokens"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requests = container.lenientInt(.requests) ?? 0
        failedRequests = container.lenientInt(.failedRequests) ?? 0
        inputTokens = container.lenientInt(.inputTokens) ?? 0
        outputTokens = container.lenientInt(.outputTokens) ?? 0
        reasoningTokens = container.lenientInt(.reasoningTokens) ?? 0
        cacheReadTokens = container.lenientInt(.cacheReadTokens) ?? 0
        cacheCreationTokens = container.lenientInt(.cacheCreationTokens) ?? 0
        totalTokens = container.lenientInt(.totalTokens) ?? 0
    }

    public static func + (lhs: TokenCounters, rhs: TokenCounters) -> TokenCounters {
        var sum = TokenCounters()
        sum.requests = lhs.requests + rhs.requests
        sum.failedRequests = lhs.failedRequests + rhs.failedRequests
        sum.inputTokens = lhs.inputTokens + rhs.inputTokens
        sum.outputTokens = lhs.outputTokens + rhs.outputTokens
        sum.reasoningTokens = lhs.reasoningTokens + rhs.reasoningTokens
        sum.cacheReadTokens = lhs.cacheReadTokens + rhs.cacheReadTokens
        sum.cacheCreationTokens = lhs.cacheCreationTokens + rhs.cacheCreationTokens
        sum.totalTokens = lhs.totalTokens + rhs.totalTokens
        return sum
    }
}

public struct ClientKeyModelUsage: Decodable, Sendable, Equatable {
    public var provider: String
    public var model: String
    public var counters: TokenCounters

    enum CodingKeys: String, CodingKey { case provider, model }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = container.lenientString(.provider) ?? ""
        model = container.lenientString(.model) ?? ""
        counters = try TokenCounters(from: decoder)
    }
}

public struct ClientKeyUsage: Decodable, Sendable, Equatable {
    public var name: String
    public var revoked: Bool
    public var counters: TokenCounters
    public var models: [ClientKeyModelUsage]

    enum CodingKeys: String, CodingKey { case name, revoked, models }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenientString(.name) ?? ""
        revoked = container.lenientBool(.revoked) ?? false
        counters = try TokenCounters(from: decoder)
        models = try container.decodeIfPresent([ClientKeyModelUsage].self, forKey: .models) ?? []
    }
}
