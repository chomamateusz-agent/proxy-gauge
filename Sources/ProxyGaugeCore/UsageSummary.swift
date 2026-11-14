import Foundation

public struct UsageBucket: Sendable, Equatable, Identifiable {
    public var index: Int
    public var label: String
    public var success: Int64
    public var failed: Int64

    public var id: Int { index }
}

public struct ProviderRequestTotals: Sendable, Equatable, Identifiable {
    public var provider: String
    public var success: Int64
    public var failed: Int64

    public var id: String { provider }
    public var total: Int64 { success + failed }
}

public struct ModelTokenUsage: Sendable, Equatable, Identifiable {
    public var provider: String
    public var model: String
    public var counters: TokenCounters

    public var id: String { provider + "/" + model }
}

public struct UsageSummary: Sendable, Equatable {
    public var success: Int64
    public var failed: Int64
    public var buckets: [UsageBucket]
    public var providers: [ProviderRequestTotals]

    public var total: Int64 { success + failed }

    public var failureRate: Double? {
        total == 0 ? nil : Double(failed) / Double(total)
    }

    public static func from(credentials: [Credential], keyCounters: [ProviderKeyCounters]) -> UsageSummary {
        var providerTotals: [String: ProviderRequestTotals] = [:]
        for credential in credentials {
            var entry = providerTotals[credential.provider] ?? ProviderRequestTotals(provider: credential.provider, success: 0, failed: 0)
            entry.success += credential.success
            entry.failed += credential.failed
            providerTotals[credential.provider] = entry
        }
        for counters in keyCounters {
            var entry = providerTotals[counters.provider] ?? ProviderRequestTotals(provider: counters.provider, success: 0, failed: 0)
            entry.success += counters.success
            entry.failed += counters.failed
            providerTotals[counters.provider] = entry
        }
        let providers = providerTotals.values.sorted { $0.total == $1.total ? $0.provider < $1.provider : $0.total > $1.total }
        return UsageSummary(
            success: providers.reduce(0) { $0 + $1.success },
            failed: providers.reduce(0) { $0 + $1.failed },
            buckets: mergedBuckets(credentials.map(\.recentRequests)),
            providers: providers
        )
    }

    public static func mergedBuckets(_ series: [[RequestBucket]]) -> [UsageBucket] {
        let length = series.map(\.count).max() ?? 0
        guard length > 0 else { return [] }
        var merged = (0..<length).map { UsageBucket(index: $0, label: "", success: 0, failed: 0) }
        for buckets in series {
            let offset = length - buckets.count
            for (position, bucket) in buckets.enumerated() {
                let index = offset + position
                merged[index].success += bucket.success
                merged[index].failed += bucket.failed
                if merged[index].label.isEmpty { merged[index].label = bucket.time }
            }
        }
        return merged
    }
}

public struct TokenUsageSummary: Sendable, Equatable {
    public var totals: TokenCounters
    public var models: [ModelTokenUsage]
    public var from: Date?
    public var to: Date?

    public static func from(_ report: ClientKeyUsageReport) -> TokenUsageSummary {
        var byModel: [String: ModelTokenUsage] = [:]
        for key in report.keys {
            for model in key.models {
                let id = model.provider + "/" + model.model
                var entry = byModel[id] ?? ModelTokenUsage(provider: model.provider, model: model.model, counters: TokenCounters())
                entry.counters = entry.counters + model.counters
                byModel[id] = entry
            }
        }
        let models = byModel.values.sorted {
            $0.counters.totalTokens == $1.counters.totalTokens ? $0.id < $1.id : $0.counters.totalTokens > $1.counters.totalTokens
        }
        return TokenUsageSummary(
            totals: report.keys.map(\.counters).reduce(TokenCounters(), +),
            models: models,
            from: report.from,
            to: report.to
        )
    }
}
