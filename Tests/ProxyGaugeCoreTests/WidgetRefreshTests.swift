import Foundation
import Testing
@testable import ProxyGaugeCore

final class InMemorySnapshotCache: SnapshotCache, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [UUID: HeadroomSnapshot] = [:]
    private var attempts: [UUID: Date] = [:]
    private var latches: [UUID: AuthFailureLatch] = [:]
    private var generations: [UUID: Int] = [:]

    func snapshot(for serverID: UUID) -> HeadroomSnapshot? { lock.withLock { snapshots[serverID] } }
    func saveSnapshot(_ snapshot: HeadroomSnapshot) { lock.withLock { snapshots[snapshot.serverID] = snapshot } }
    func saveSnapshot(_ snapshot: HeadroomSnapshot, authGeneration: Int) {
        lock.withLock {
            guard generations[snapshot.serverID, default: 0] == authGeneration else { return }
            snapshots[snapshot.serverID] = snapshot
        }
    }
    func lastWidgetFetchAttempt(for serverID: UUID) -> Date? { lock.withLock { attempts[serverID] } }
    func recordWidgetFetchAttempt(_ date: Date, for serverID: UUID) { lock.withLock { attempts[serverID] = date } }
    func authGeneration(for serverID: UUID) -> Int { lock.withLock { generations[serverID, default: 0] } }
    func retire(_ serverID: UUID) {
        lock.withLock {
            generations[serverID, default: 0] += 1
            snapshots[serverID] = nil
        }
    }
    func authFailureLatch(for serverID: UUID, generation: Int) -> AuthFailureLatch { lock.withLock { latches[serverID] ?? AuthFailureLatch() } }
    func saveAuthFailureLatch(_ latch: AuthFailureLatch, for serverID: UUID, generation: Int) { lock.withLock { latches[serverID] = latch } }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@Suite("Widget refresh budget")
struct WidgetRefreshTests {
    let start = date("2026-11-14T10:00:00Z")
    let management = ServerProfile(name: "Home", baseURL: testBaseURL, authMode: .management)
    let clientKey = ServerProfile(name: "Home", baseURL: testBaseURL, authMode: .clientKey)

    func refresher(_ cache: InMemorySnapshotCache, clock: TestClock, transport: StubTransport) -> WidgetSnapshotRefresher {
        WidgetSnapshotRefresher(cache: cache, clock: { clock.now }) { profile in
            try await HeadroomLoader.load(profile: profile, secret: "k", transport: transport, now: clock.now)
        }
    }

    func snapshot(_ profile: ServerProfile, at generatedAt: Date) -> HeadroomSnapshot {
        .management(profile, credentials: [], now: generatedAt)
    }

    @Test func decisionReusesASnapshotYoungerThanTheInterval() {
        let fresh = snapshot(management, at: start.addingTimeInterval(-14 * 60))
        let old = snapshot(management, at: start.addingTimeInterval(-15 * 60))
        let future = snapshot(management, at: start.addingTimeInterval(3600))
        #expect(WidgetRefreshPolicy.decide(cached: fresh, lastAttempt: nil, latch: AuthFailureLatch(), now: start) == .reuse)
        #expect(WidgetRefreshPolicy.decide(cached: old, lastAttempt: nil, latch: AuthFailureLatch(), now: start) == .fetch)
        #expect(WidgetRefreshPolicy.decide(cached: nil, lastAttempt: nil, latch: AuthFailureLatch(), now: start) == .fetch)
        #expect(WidgetRefreshPolicy.decide(cached: future, lastAttempt: nil, latch: AuthFailureLatch(), now: start) == .fetch)
    }

    @Test func decisionWaitsAfterARecentFailedAttempt() {
        let old = snapshot(management, at: start.addingTimeInterval(-3600))
        #expect(WidgetRefreshPolicy.decide(cached: old, lastAttempt: start.addingTimeInterval(-60), latch: AuthFailureLatch(), now: start) == .waitForNextInterval)
        #expect(WidgetRefreshPolicy.decide(cached: old, lastAttempt: start.addingTimeInterval(-15 * 60), latch: AuthFailureLatch(), now: start) == .fetch)
    }

    @Test(arguments: [AuthPauseReason.keyRejected, .ipBanned])
    func decisionNeverFetchesWhileAuthIsPaused(reason: AuthPauseReason) {
        let latch = AuthFailureLatch(pauseReason: reason)
        #expect(WidgetRefreshPolicy.decide(cached: nil, lastAttempt: nil, latch: latch, now: start) == .paused(reason))
    }

    @Test func manyTimelineRequestsWithinTheIntervalSendOneManagementRequest() async {
        let stub = StubTransport { _ in .json(#"{"files":[]}"#) }
        let clock = TestClock(start)
        let widget = refresher(InMemorySnapshotCache(), clock: clock, transport: stub)
        var origins: [WidgetSnapshot.Origin] = []
        for _ in 0..<20 {
            origins.append(await widget.snapshot(for: management).origin)
            clock.advance(by: 44)
        }
        #expect(stub.requests.count == 1)
        #expect(stub.managementRequestCount == 1)
        #expect(stub.requests.first?.url.path() == "/v8/management/credentials")
        #expect(origins.first == .fetched)
        #expect(origins.dropFirst().allSatisfy { $0 == .reused })

        clock.advance(by: 15 * 60)
        _ = await widget.snapshot(for: management)
        #expect(stub.managementRequestCount == 2)
    }

    @Test func concurrentWidgetsShareOneFetch() async {
        let stub = StubTransport { _ in .json(#"{"files":[]}"#) }
        let widget = refresher(InMemorySnapshotCache(), clock: TestClock(start), transport: stub)
        let profile = management
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { _ = await widget.snapshot(for: profile) }
            }
        }
        #expect(stub.managementRequestCount == 1)
    }

    @Test func snapshotPublishedByTheAppIsReusedWithoutAnyRequest() async {
        let stub = StubTransport { _ in .json(#"{"files":[]}"#) }
        let cache = InMemorySnapshotCache()
        cache.saveSnapshot(snapshot(management, at: start.addingTimeInterval(-60)))
        let result = await refresher(cache, clock: TestClock(start), transport: stub).snapshot(for: management)
        #expect(result.origin == .reused)
        #expect(stub.requests.isEmpty)
    }

    @Test func failedFetchIsNotRetriedWithinTheInterval() async {
        let stub = StubTransport { _ in throw APIError.transport("offline") }
        let clock = TestClock(start)
        let widget = refresher(InMemorySnapshotCache(), clock: clock, transport: stub)
        for _ in 0..<10 {
            _ = await widget.snapshot(for: management)
            clock.advance(by: 60)
        }
        #expect(stub.requests.count == 1)
    }

    @Test(arguments: AuthRequestBudgetTests.rejections)
    func rejectionPausesEveryLaterWidgetFetch(rejection: HTTPResponse) async {
        let stub = StubTransport { _ in rejection }
        let clock = TestClock(start)
        let cache = InMemorySnapshotCache()
        let widget = refresher(cache, clock: clock, transport: stub)
        let first = await widget.snapshot(for: management)
        #expect(first.pauseReason != nil)
        for _ in 0..<8 {
            clock.advance(by: 20 * 60)
            #expect(await widget.snapshot(for: management).origin == .paused)
        }
        #expect(stub.managementRequestCount == 1)
    }

    @Test func clientKeyModeSendsOneFleetLimitsRequest() async {
        let stub = StubTransport { _ in .json(#"{"object":"fleet.limits","credentials":[],"summary":{}}"#) }
        let clock = TestClock(start)
        let widget = refresher(InMemorySnapshotCache(), clock: clock, transport: stub)
        for _ in 0..<5 {
            _ = await widget.snapshot(for: clientKey)
            clock.advance(by: 120)
        }
        #expect(stub.requests.map { $0.url.path() } == ["/v1/fleet/limits"])
        #expect(stub.managementRequestCount == 0)
    }

    @Test func timelineAddsEntriesWhenPooledCapacityGrowsWithinTheInterval() {
        let account = PoolAccount(provider: "claude", availability: .blocked(until: start.addingTimeInterval(300)), bars: [
            QuotaBar(id: "session_5h", usedPercent: 80, resetsAt: start.addingTimeInterval(600)),
            QuotaBar(id: "weekly_all", usedPercent: 10, resetsAt: start.addingTimeInterval(86_400))
        ])
        var cached = snapshot(management, at: start)
        cached.poolAccounts = [account]
        #expect(WidgetRefreshPolicy.entryDates(for: cached, from: start) == [start, start.addingTimeInterval(300), start.addingTimeInterval(600), start.addingTimeInterval(15 * 60 + 1)])
        #expect(WidgetRefreshPolicy.entryDates(for: nil, from: start) == [start])
    }

    @Test func timelineMarksTheSnapshotStaleEvenWhenTheNextReloadIsLate() throws {
        let cached = snapshot(management, at: start.addingTimeInterval(-10 * 60))
        let dates = WidgetRefreshPolicy.entryDates(for: cached, from: start)
        let staleEntry = try #require(dates.last)
        #expect(dates == [start, start.addingTimeInterval(5 * 60 + 1)])
        #expect(!WidgetRefreshPolicy.isStale(cached.generatedAt, at: start))
        #expect(WidgetRefreshPolicy.isStale(cached.generatedAt, at: staleEntry))
        #expect(WidgetRefreshPolicy.entryDates(for: snapshot(management, at: start.addingTimeInterval(-3600)), from: start) == [start])
    }

    @Test func nextReloadFollowsTheAgeOfTheReusedSnapshot() {
        let reused = snapshot(management, at: start.addingTimeInterval(-14 * 60))
        let old = snapshot(management, at: start.addingTimeInterval(-3600))
        #expect(WidgetRefreshPolicy.nextReload(for: reused, from: start) == start.addingTimeInterval(60))
        #expect(WidgetRefreshPolicy.nextReload(for: old, from: start) == start.addingTimeInterval(15 * 60))
        #expect(WidgetRefreshPolicy.nextReload(for: nil, from: start) == start.addingTimeInterval(15 * 60))
    }

    @Test func lateFetchAfterAServerEditDoesNotSaveTheOldServersSnapshot() async {
        let cache = InMemorySnapshotCache()
        let profile = management
        let widget = WidgetSnapshotRefresher(cache: cache, clock: { date("2026-11-14T10:00:00Z") }) { profile in
            cache.retire(profile.id)
            return .management(profile, credentials: [], now: date("2026-11-14T10:00:00Z"))
        }
        let result = await widget.snapshot(for: profile)
        #expect(result.origin == .waiting)
        #expect(result.snapshot == nil)
        #expect(cache.snapshot(for: profile.id) == nil)
    }
}
