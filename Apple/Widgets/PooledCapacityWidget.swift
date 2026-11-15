import AppIntents
import ProxyGaugeCore
import ProxyGaugeStore
import SwiftUI
import WidgetKit

struct PooledCapacityIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Pooled capacity"
    static let description = IntentDescription("Remaining quota of all your accounts added up, per provider.")

    @Parameter(title: "Server", description: "Leave empty to follow the default server.")
    var server: ServerEntity?

    @Parameter(title: "Primary provider", description: "Leave empty to show the provider with the least capacity left.")
    var provider: ProviderEntity?
}

struct PooledCapacityEntry: TimelineEntry {
    var date: Date
    var serverName: String?
    var snapshot: HeadroomSnapshot?
    var isStale: Bool
    var showsSavedAge = false
    var pauseReason: AuthPauseReason?
    var primaryProvider: String?
    var link: URL?

    var pools: [ProviderPool] { snapshot?.pools(at: date) ?? [] }
}

struct PooledCapacityTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PooledCapacityEntry {
        PooledCapacityEntry(date: .now, serverName: nil, snapshot: Self.sample, isStale: false)
    }

    func snapshot(for configuration: PooledCapacityIntent, in context: Context) async -> PooledCapacityEntry {
        if context.isPreview {
            return placeholder(in: context)
        }
        return await entries(configuration).first ?? placeholder(in: context)
    }

    func timeline(for configuration: PooledCapacityIntent, in context: Context) async -> Timeline<PooledCapacityEntry> {
        let entries = await entries(configuration)
        return Timeline(entries: entries, policy: .after(WidgetRefreshPolicy.nextReload(for: entries.first?.snapshot, from: .now)))
    }

    private func entries(_ configuration: PooledCapacityIntent) async -> [PooledCapacityEntry] {
        guard let (profile, refreshesAutomatically) = WidgetData.profile(configuration.server?.id) else {
            return [PooledCapacityEntry(date: .now, serverName: nil, snapshot: nil, isStale: false)]
        }
        let link = WidgetData.overviewLink(profile)
        let primary = configuration.provider?.id
        return await WidgetData.timeline(for: profile, refreshesAutomatically: refreshesAutomatically) { date, result in
            PooledCapacityEntry(
                date: date,
                serverName: profile.isDemo ? nil : profile.name,
                snapshot: result.snapshot,
                isStale: result.isStale,
                showsSavedAge: result.origin == .saved,
                pauseReason: result.pauseReason,
                primaryProvider: primary,
                link: link
            )
        }
    }

    static let sample: HeadroomSnapshot = {
        let now = Date.now
        func account(_ provider: String, session: Double, weekly: Double) -> PoolAccount {
            PoolAccount(provider: provider, availability: .available, bars: [
                QuotaBar(id: "session_5h", usedPercent: session, resetsAt: now.addingTimeInterval(5400), sampledAt: now),
                QuotaBar(id: "weekly_all", usedPercent: weekly, resetsAt: now.addingTimeInterval(259_200), sampledAt: now)
            ])
        }
        return HeadroomSnapshot(
            serverID: ServerProfile.demoID,
            serverName: "Demo server",
            isDemo: true,
            generatedAt: now,
            source: .passiveObservations,
            providers: [],
            poolAccounts: [
                account("claude", session: 20, weekly: 34),
                account("claude", session: 50, weekly: 61),
                account("claude", session: 43, weekly: 18),
                account("codex", session: 71, weekly: 80),
                account("codex", session: 12, weekly: 55)
            ]
        )
    }()
}

struct PooledCapacityWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "PooledCapacityWidget", intent: PooledCapacityIntent.self, provider: PooledCapacityTimelineProvider()) { entry in
            PooledCapacityWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(entry.link)
        }
        .configurationDisplayName(Text("Pooled capacity"))
        .description(Text("Remaining quota of all your accounts added up, per provider."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular])
    }
}

struct PooledCapacityWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PooledCapacityEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            PooledCircularView(window: primaryWindow)
        case .accessoryRectangular:
            PooledRectangularView(pool: primaryPool, window: primaryWindow)
        default:
            homeScreenBody
        }
    }

    private var primaryPool: ProviderPool? { entry.pools.primary(entry.primaryProvider) }

    private var primaryWindow: PooledWindow? { primaryPool?.bindingWindow }

    private var homeScreenBody: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 8) {
            PooledWidgetHeader(entry: entry)
            if let reason = entry.pauseReason {
                Text(reason.widgetNote)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if let message = emptyMessage {
                Spacer(minLength: 0)
                message
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if entry.snapshot == nil {
                Spacer(minLength: 0)
            } else if family == .systemSmall {
                PooledSmallBody(pool: primaryPool, window: primaryWindow)
                Spacer(minLength: 0)
                PooledFreshnessFooter(entry: entry, window: primaryWindow)
            } else {
                PooledProviderList(entry: entry, showsAllWindows: family == .systemLarge)
                Spacer(minLength: 0)
                PooledFreshnessFooter(entry: entry, window: primaryWindow)
            }
        }
    }

    private var emptyMessage: Text? {
        guard let snapshot = entry.snapshot else {
            if entry.pauseReason != nil { return nil }
            if entry.showsSavedAge { return Text("Automatic refresh is off. Refresh in Proxy Gauge to save values.") }
            return entry.isStale ? Text("Could not reach the server yet.") : Text("Open Proxy Gauge and choose a default server.")
        }
        if snapshot.source == .unavailable { return Text("This server shares no quota with client keys.") }
        if entry.pools.isEmpty { return Text("No accounts yet.") }
        return nil
    }
}

private struct PooledWidgetHeader: View {
    let entry: PooledCapacityEntry

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.tint)
            Group {
                if let name = entry.serverName {
                    Text(verbatim: name)
                } else {
                    Text("Demo server")
                }
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            Spacer(minLength: 0)
            if let reason = entry.pauseReason {
                Image(systemName: reason.symbol)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
            } else if entry.isStale {
                Image(systemName: "wifi.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("Showing the last saved values"))
            }
        }
    }
}

private struct PooledSmallBody: View {
    let pool: ProviderPool?
    let window: PooledWindow?

    var body: some View {
        if let pool {
            HStack(spacing: 6) {
                ProviderBadge(provider: pool.provider, size: 18)
                Text(ProviderCatalog.displayName(pool.provider))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            if let window {
                Text(HeadroomStyle.percentText(window.remainingPercent))
                    .font(.system(.title, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundStyle(window.color)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("of \(HeadroomStyle.percentText(window.capacityPercent)) · \(window.title)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                PooledCapacityBar(window: window, height: 6)
            } else {
                Text("No quota data reported yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PooledProviderList: View {
    @Environment(\.widgetFamily) private var family
    let entry: PooledCapacityEntry
    let showsAllWindows: Bool

    var body: some View {
        let limit = showsAllWindows ? 3 : 2
        ForEach(Array(orderedPools.prefix(limit))) { pool in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ProviderBadge(provider: pool.provider, size: 18)
                    Text(ProviderCatalog.displayName(pool.provider))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    AccountCountText(pool: pool)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let next = pool.nextIncreaseAt, next > entry.date {
                        Text("More in \(Text(next, style: .relative))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                let windows = showsAllWindows ? pool.windows : pool.headlineWindows(limit: 2)
                if windows.isEmpty {
                    Text("No quota data reported yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if showsAllWindows {
                    ForEach(windows) { window in
                        PooledWindowRow(window: window, compact: true)
                    }
                } else {
                    HStack(spacing: 10) {
                        ForEach(windows) { window in
                            PooledWindowRow(window: window, compact: true)
                        }
                    }
                }
            }
        }
    }

    private var orderedPools: [ProviderPool] {
        let pools = entry.pools
        guard let primary = pools.primary(entry.primaryProvider) else { return pools }
        return [primary] + pools.filter { $0.provider != primary.provider }
    }
}

private struct PooledFreshnessFooter: View {
    let entry: PooledCapacityEntry
    let window: PooledWindow?

    var body: some View {
        if let snapshot = entry.snapshot {
            let sampledAt = window?.dataSampledAt(snapshotTakenAt: snapshot.generatedAt) ?? snapshot.generatedAt
            if entry.showsSavedAge {
                Text("Saved \(Text(snapshot.generatedAt, style: .relative)) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if WidgetRefreshPolicy.isStale(sampledAt, at: entry.date) {
                Text("Sampled \(Text(sampledAt, style: .relative)) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let unknown = window?.unknownAccounts, unknown > 0 {
                Text("Accounts without data: \(unknown)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct PooledRectangularView: View {
    let pool: ProviderPool?
    let window: PooledWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let pool {
                Text(ProviderCatalog.displayName(pool.provider))
                    .font(.headline)
                    .lineLimit(1)
            }
            if let window {
                window.amountText
                    .font(.body.monospacedDigit())
                    .lineLimit(1)
                Gauge(value: window.remainingShareOfCapacity ?? 0) {
                    window.title
                }
                .gaugeStyle(.accessoryLinearCapacity)
            } else {
                Text("No quota data reported yet")
                    .font(.caption)
            }
        }
        .widgetAccentable()
    }
}

private struct PooledCircularView: View {
    let window: PooledWindow?

    var body: some View {
        if let window {
            Gauge(value: window.remainingShareOfCapacity ?? 0) {
                Image(systemName: "square.stack.3d.up.fill")
            } currentValueLabel: {
                Text(verbatim: "\(Int(window.remainingPercent.rounded()))")
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.stack.3d.up.slash")
            }
        }
    }
}
