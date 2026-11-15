import Foundation

public protocol SnapshotCache: Sendable {
    func snapshot(for serverID: UUID) -> HeadroomSnapshot?
    func saveSnapshot(_ snapshot: HeadroomSnapshot, authGeneration: Int)
    func lastWidgetFetchAttempt(for serverID: UUID) -> Date?
    func recordWidgetFetchAttempt(_ date: Date, for serverID: UUID)
    func authGeneration(for serverID: UUID) -> Int
    func authFailureLatch(for serverID: UUID, generation: Int) -> AuthFailureLatch
    func saveAuthFailureLatch(_ latch: AuthFailureLatch, for serverID: UUID, generation: Int)
}

public enum WidgetRefreshDecision: Sendable, Equatable {
    case reuse
    case fetch
    case paused(AuthPauseReason)
    case waitForNextInterval
    case automaticRefreshOff
}

public enum WidgetRefreshPolicy {
    public static let interval: TimeInterval = 15 * 60
    static let toleratedClockSkew: TimeInterval = 60
    static let maximumEntriesPerTimeline = 8

    public static func decide(
        cached: HeadroomSnapshot?,
        lastAttempt: Date?,
        latch: AuthFailureLatch,
        now: Date,
        interval: TimeInterval = interval,
        refreshesAutomatically: Bool = true
    ) -> WidgetRefreshDecision {
        if let reason = latch.pauseReason { return .paused(reason) }
        if !refreshesAutomatically { return .automaticRefreshOff }
        if let cached, isRecent(cached.generatedAt, now: now, interval: interval) { return .reuse }
        if let lastAttempt, isRecent(lastAttempt, now: now, interval: interval) { return .waitForNextInterval }
        return .fetch
    }

    public static func entryDates(for snapshot: HeadroomSnapshot?, from now: Date, interval: TimeInterval = interval) -> [Date] {
        let end = now.addingTimeInterval(interval)
        let growth = Set((snapshot?.poolAccounts ?? []).flatMap(\.growthDates)).filter { $0 > now && $0 < end }
        let staleness = (snapshot.map { [staleAt($0.generatedAt, interval: interval)] } ?? []).filter { $0 > now }
        return [now] + growth.sorted().prefix(maximumEntriesPerTimeline - 2) + staleness
    }

    public static func staleAt(_ sampledAt: Date, interval: TimeInterval = interval) -> Date {
        sampledAt.addingTimeInterval(interval + 1)
    }

    public static func isStale(_ sampledAt: Date, at now: Date, interval: TimeInterval = interval) -> Bool {
        now >= staleAt(sampledAt, interval: interval)
    }

    public static func nextReload(for snapshot: HeadroomSnapshot?, from now: Date, interval: TimeInterval = interval) -> Date {
        guard let generatedAt = snapshot?.generatedAt, isRecent(generatedAt, now: now, interval: interval) else {
            return now.addingTimeInterval(interval)
        }
        return generatedAt.addingTimeInterval(interval)
    }

    private static func isRecent(_ date: Date, now: Date, interval: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(date)
        return age < interval && age > -toleratedClockSkew
    }
}

private extension PoolAccount {
    var growthDates: [Date] {
        var dates = bars.compactMap(\.resetsAt)
        if case .blocked(let until?) = availability { dates.append(until) }
        return dates
    }
}

public struct WidgetSnapshot: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        case fetched
        case reused
        case paused
        case failed
        case waiting
        case saved
    }

    public var snapshot: HeadroomSnapshot?
    public var origin: Origin
    public var pauseReason: AuthPauseReason?

    public init(snapshot: HeadroomSnapshot?, origin: Origin, pauseReason: AuthPauseReason? = nil) {
        self.snapshot = snapshot
        self.origin = origin
        self.pauseReason = pauseReason
    }

    public var isStale: Bool {
        switch origin {
        case .fetched, .reused, .saved: false
        case .paused, .failed, .waiting: true
        }
    }
}

public actor WidgetSnapshotRefresher {
    public typealias Loader = @Sendable (ServerProfile) async throws -> HeadroomSnapshot

    private let cache: any SnapshotCache
    private let interval: TimeInterval
    private let clock: @Sendable () -> Date
    private let load: Loader
    private var inFlight: [UUID: Task<WidgetSnapshot, Never>] = [:]

    public init(cache: any SnapshotCache, interval: TimeInterval = WidgetRefreshPolicy.interval, clock: @escaping @Sendable () -> Date = { Date() }, load: @escaping Loader) {
        self.cache = cache
        self.interval = interval
        self.clock = clock
        self.load = load
    }

    public func snapshot(for profile: ServerProfile, refreshesAutomatically: Bool = true) async -> WidgetSnapshot {
        if let running = inFlight[profile.id] { return await running.value }
        let task = Task { await resolve(profile, refreshesAutomatically: refreshesAutomatically) }
        inFlight[profile.id] = task
        let result = await task.value
        inFlight[profile.id] = nil
        return result
    }

    private func resolve(_ profile: ServerProfile, refreshesAutomatically: Bool) async -> WidgetSnapshot {
        let generation = cache.authGeneration(for: profile.id)
        var latch = profile.isDemo ? AuthFailureLatch() : cache.authFailureLatch(for: profile.id, generation: generation)
        let cached = cache.snapshot(for: profile.id)
        let now = clock()
        switch WidgetRefreshPolicy.decide(cached: cached, lastAttempt: cache.lastWidgetFetchAttempt(for: profile.id), latch: latch, now: now, interval: interval, refreshesAutomatically: refreshesAutomatically) {
        case .paused(let reason):
            return WidgetSnapshot(snapshot: cached, origin: .paused, pauseReason: reason)
        case .reuse:
            return WidgetSnapshot(snapshot: cached, origin: .reused)
        case .waitForNextInterval:
            return WidgetSnapshot(snapshot: cached, origin: .waiting)
        case .automaticRefreshOff:
            return WidgetSnapshot(snapshot: cached, origin: .saved)
        case .fetch:
            cache.recordWidgetFetchAttempt(now, for: profile.id)
            do {
                let fresh = try await load(profile)
                guard cache.authGeneration(for: profile.id) == generation else {
                    return WidgetSnapshot(snapshot: cache.snapshot(for: profile.id), origin: .waiting)
                }
                cache.saveSnapshot(fresh, authGeneration: generation)
                return WidgetSnapshot(snapshot: fresh, origin: .fetched)
            } catch {
                latch.record(APIError.wrapping(error))
                if latch.isBlocked && !profile.isDemo {
                    cache.saveAuthFailureLatch(latch, for: profile.id, generation: generation)
                }
                return WidgetSnapshot(snapshot: cached, origin: .failed, pauseReason: latch.pauseReason)
            }
        }
    }
}
