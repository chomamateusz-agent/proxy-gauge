import Foundation

public struct ModelCatalog: Sendable, Equatable {
    public var models: [ModelInfo]
    public var providers: [String: Set<String>]
    public var failedAccounts: [String]

    public init(models: [ModelInfo] = [], providers: [String: Set<String>] = [:], failedAccounts: [String] = []) {
        self.models = models
        self.providers = providers
        self.failedAccounts = failedAccounts
    }

    public static let maximumConcurrentRequests = 4

    private typealias Target = (name: String, provider: String)
    private typealias Fetched = (target: Target, models: [ModelInfo]?)

    public static func load(from client: ManagementClient, credentials: [Credential]) async throws -> ModelCatalog {
        let targets: [Target] = credentials.filter { !$0.disabled }.map { ($0.name, $0.provider) }
        guard let first = targets.first else { return ModelCatalog() }
        var builder = Builder()
        builder.add(try await fetch(first, from: client))
        try await withThrowingTaskGroup(of: Fetched.self) { group in
            var remaining = targets.dropFirst().makeIterator()
            func enqueueNext() {
                guard let target = remaining.next() else { return }
                group.addTask { try await fetch(target, from: client) }
            }
            for _ in 0..<maximumConcurrentRequests { enqueueNext() }
            while let fetched = try await group.next() {
                builder.add(fetched)
                enqueueNext()
            }
        }
        return builder.catalog
    }

    private static func fetch(_ target: Target, from client: ManagementClient) async throws -> Fetched {
        do {
            return (target, try await client.credentialModels(name: target.name))
        } catch let error as APIError where !error.isAuthenticationFailure {
            return (target, nil)
        }
    }

    private struct Builder {
        var collected: [String: ModelInfo] = [:]
        var providers: [String: Set<String>] = [:]
        var failed: [String] = []

        mutating func add(_ fetched: Fetched) {
            guard let models = fetched.models else {
                failed.append(fetched.target.name)
                return
            }
            for model in models {
                collected[model.id] = collected[model.id] ?? model
                providers[model.id, default: []].insert(fetched.target.provider)
            }
        }

        var catalog: ModelCatalog {
            ModelCatalog(models: collected.values.sorted { $0.id < $1.id }, providers: providers, failedAccounts: failed.sorted())
        }
    }
}
