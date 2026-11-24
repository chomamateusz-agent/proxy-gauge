import Foundation

public struct RouterSettings: Sendable, Equatable {
    public static let defaultShortWindowCapPercent = 95.0
    public static let useOrLose = "use-or-lose"
    public static let defaults = RouterSettings(strategy: "round-robin")

    public var strategy: String
    public var shortWindowCapPercent: Double
    public var drainEndingCredentials: Bool

    public init(strategy: String?, shortWindowCapPercent: Double? = nil, drainEndingCredentials: Bool? = nil) {
        self.strategy = Self.normalizedStrategy(strategy)
        self.shortWindowCapPercent = shortWindowCapPercent.flatMap { $0 > 1 && $0 <= 100 ? $0 : nil } ?? Self.defaultShortWindowCapPercent
        self.drainEndingCredentials = drainEndingCredentials ?? true
    }

    public var ranksByUseOrLose: Bool { strategy == Self.useOrLose }

    private static let aliases: [String: String] = [
        "weighted-round-robin": "weighted-round-robin",
        "weightedroundrobin": "weighted-round-robin",
        "wrr": "weighted-round-robin",
        "fill-first": "fill-first",
        "fillfirst": "fill-first",
        "ff": "fill-first",
        "nearest-reset": "nearest-reset",
        "nearestreset": "nearest-reset",
        "nr": "nearest-reset",
        "use-or-lose": "use-or-lose",
        "most-used": "most-used",
        "mostused": "most-used",
        "mu": "most-used"
    ]

    public static func normalizedStrategy(_ value: String?) -> String {
        value.flatMap { aliases[$0.trimmingCharacters(in: .whitespaces).lowercased()] } ?? "round-robin"
    }
}

public struct RouterWindow: Sendable, Equatable {
    public var usedPercent: Double?
    public var resetsAt: Date?

    public init(usedPercent: Double?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct RouterReadings: Sendable, Equatable {
    public var weekly: RouterWindow?
    public var fable: RouterWindow?
    public var short: RouterWindow?
    public var creditsAvailable: Bool
    public var observedAt: Date

    public init(weekly: RouterWindow?, fable: RouterWindow? = nil, short: RouterWindow?, creditsAvailable: Bool = false, observedAt: Date) {
        self.weekly = weekly
        self.fable = fable
        self.short = short
        self.creditsAvailable = creditsAvailable
        self.observedAt = observedAt
    }
}

public enum RouterFamily: Sendable {
    case all
    case fable
}

public enum RouterOutOfRotation: Sendable, Equatable, CaseIterable {
    case cooling
    case disabled
    case ended
}

public enum RouterTier: Sendable, Equatable, Hashable {
    case room
    case capped
    case limited
}

public enum RouterPlacement: Sendable, Equatable {
    case ranked(position: Int, tier: RouterTier, sampled: Bool, sampledProvider: Bool)
    case out(RouterOutOfRotation)
}

public struct RouterCandidate<Item: Sendable>: Sendable {
    public var item: Item
    public var provider: String
    public var priority: Int
    public var endsAt: Date?
    public var readings: RouterReadings?
    public var outOfRotation: RouterOutOfRotation?

    public init(item: Item, provider: String, priority: Int = 0, endsAt: Date? = nil, readings: RouterReadings?, outOfRotation: RouterOutOfRotation? = nil) {
        self.item = item
        self.provider = provider
        self.priority = priority
        self.endsAt = endsAt
        self.readings = readings
        self.outOfRotation = outOfRotation
    }
}

public struct RankedCandidate<Item: Sendable>: Sendable {
    public var candidate: RouterCandidate<Item>
    public var placement: RouterPlacement
}

public enum RouterOrder {
    public static let sampledProviders: Set<String> = ["claude", "codex"]

    static let hour: TimeInterval = 3_600
    static let week: TimeInterval = 7 * 86_400
    static let shortWindow: TimeInterval = 5 * 3_600
    static let idleSampleAge: TimeInterval = 15 * 60

    struct Sample {
        var resetsAt: Date?
        var utilisation: Double
        var sampled: Bool
        var capped: Bool
        var atLimit: Bool

        var tier: RouterTier { atLimit ? .limited : capped ? .capped : .room }
    }

    public static func rank<Item>(_ candidates: [RouterCandidate<Item>], family: RouterFamily = .all, settings: RouterSettings, now: Date) -> [RankedCandidate<Item>] {
        var providers: [String] = []
        for candidate in candidates where !providers.contains(candidate.provider) {
            providers.append(candidate.provider)
        }
        return providers.flatMap { provider in
            rankProvider(candidates.filter { $0.provider == provider }, family: family, settings: settings, now: now)
        }
    }

    public static func rankProvider<Item>(_ candidates: [RouterCandidate<Item>], family: RouterFamily = .all, settings: RouterSettings, now: Date) -> [RankedCandidate<Item>] {
        let inRotation = candidates.indices.filter { candidates[$0].outOfRotation == nil }
        let samples = Dictionary(uniqueKeysWithValues: inRotation.map { ($0, sample(candidates[$0], family: family, settings: settings, now: now)) })
        var ranked: [RankedCandidate<Item>] = []
        var remaining = inRotation
        while !remaining.isEmpty {
            let next = pickNext(remaining, candidates: candidates, samples: samples)
            let sample = samples[next]!
            ranked.append(RankedCandidate(
                candidate: candidates[next],
                placement: .ranked(
                    position: ranked.count + 1,
                    tier: sample.tier,
                    sampled: sample.sampled,
                    sampledProvider: sampledProviders.contains(candidates[next].provider.lowercased())
                )
            ))
            remaining.removeAll { $0 == next }
        }
        let out = RouterOutOfRotation.allCases.flatMap { reason in
            candidates.filter { $0.outOfRotation == reason }.map { RankedCandidate(candidate: $0, placement: .out(reason)) }
        }
        return ranked + out
    }

    static func hasUsage(_ window: RouterWindow?) -> Bool {
        window?.usedPercent != nil
    }

    static func windowUsable(_ window: RouterWindow?, observedAt: Date, now: Date) -> Bool {
        guard let window, let used = window.usedPercent, observedAt.addingTimeInterval(week) > now else { return false }
        if let resetsAt = window.resetsAt { return resetsAt > now }
        return used == 0 && observedAt.addingTimeInterval(idleSampleAge) > now
    }

    static func windowAtLimit(_ window: RouterWindow?, now: Date) -> Bool {
        guard let window, let used = window.usedPercent, let resetsAt = window.resetsAt else { return false }
        return resetsAt > now && used >= 100
    }

    static func sample<Item>(_ candidate: RouterCandidate<Item>, family: RouterFamily, settings: RouterSettings, now: Date) -> Sample {
        let readings = candidate.readings
        var weekly = readings?.weekly
        var atLimit = windowAtLimit(weekly, now: now)
        if let readings, candidate.provider.lowercased() == "claude", family == .fable {
            if readings.observedAt.addingTimeInterval(week) > now { atLimit = atLimit || windowAtLimit(readings.fable, now: now) }
            if windowUsable(readings.fable, observedAt: readings.observedAt, now: now) { weekly = readings.fable }
        }
        let short = readings?.short
        let shortActive: Bool = if let short {
            short.resetsAt.map { $0 > now } ?? ((readings?.observedAt ?? .distantPast).addingTimeInterval(shortWindow) > now)
        } else {
            false
        }
        let credits = readings?.creditsAvailable == true
        var resetsAt = weekly?.resetsAt
        if settings.drainEndingCredentials, let endsAt = candidate.endsAt, resetsAt.map({ endsAt < $0 }) ?? true {
            resetsAt = endsAt
        }
        return Sample(
            resetsAt: resetsAt,
            utilisation: weekly?.usedPercent ?? 0,
            sampled: readings.map { windowUsable(weekly, observedAt: $0.observedAt, now: now) } ?? false,
            capped: !credits && shortActive && (short?.usedPercent.map { $0 >= settings.shortWindowCapPercent } ?? false),
            atLimit: !credits && (atLimit || windowAtLimit(weekly, now: now))
        )
    }

    private static func resetOrder(_ date: Date?) -> Date {
        date ?? .distantPast
    }

    static func pickNext<Item>(_ pool: [Int], candidates: [RouterCandidate<Item>], samples: [Int: Sample]) -> Int {
        let room = pool.filter { samples[$0]!.tier == .room }
        let capped = pool.filter { samples[$0]!.tier == .capped }
        var ordered = !room.isEmpty ? room : !capped.isEmpty ? capped : pool
        let bestPriority = ordered.map { candidates[$0].priority }.max() ?? 0
        ordered = ordered.filter { candidates[$0].priority == bestPriority }

        let earliest = ordered.compactMap { index -> Date? in
            let sample = samples[index]!
            return sample.sampled ? sample.resetsAt : nil
        }.min()
        var selected = ordered[0]
        var found = false
        for index in ordered {
            let sample = samples[index]!
            if !sample.sampled { continue }
            if let earliest, sample.resetsAt.map({ $0 > earliest.addingTimeInterval(hour) }) ?? true { continue }
            let best = samples[selected]!
            if !found
                || sample.utilisation < best.utilisation
                || (sample.utilisation == best.utilisation && resetOrder(sample.resetsAt) < resetOrder(best.resetsAt)) {
                selected = index
                found = true
            }
        }
        return selected
    }
}

public enum ServerLab {
    public static let forkVersionMarker = "-fleet"
    public static let routerOrderDefault = true

    public static func isFleetFork(version: String?, fleetLimitsAnswered: Bool) -> Bool {
        fleetLimitsAnswered || (version?.localizedCaseInsensitiveContains(forkVersionMarker) ?? false)
    }

    public static func routerOrderKey(serverID: UUID) -> String {
        "proxygauge.lab.router-order.\(serverID.uuidString)"
    }
}
