import AppIntents
import ProxyGaugeCore
import ProxyGaugeStore
import SwiftUI
import WidgetKit

@main
struct ProxyGaugeWidgets: WidgetBundle {
    var body: some Widget {
        HeadroomWidget()
    }
}

struct HeadroomWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Headroom"
    static let description = IntentDescription("Lowest remaining quota per provider on your default server.")
}

struct HeadroomEntry: TimelineEntry {
    var date: Date
    var snapshot: HeadroomSnapshot?
    var isStale: Bool
    var keyRejected = false
}

struct HeadroomTimelineProvider: AppIntentTimelineProvider {
    static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> HeadroomEntry {
        HeadroomEntry(date: .now, snapshot: Self.sample, isStale: false)
    }

    func snapshot(for configuration: HeadroomWidgetIntent, in context: Context) async -> HeadroomEntry {
        if context.isPreview {
            return placeholder(in: context)
        }
        return await loadEntry()
    }

    func timeline(for configuration: HeadroomWidgetIntent, in context: Context) async -> Timeline<HeadroomEntry> {
        let entry = await loadEntry()
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(Self.refreshInterval)))
    }

    private func loadEntry() async -> HeadroomEntry {
        let store = ProfileStore()
        let profile = store.load().defaultProfile
        let latchGeneration = store.authGeneration(for: profile.id)
        var latch = store.authFailureLatch(for: profile.id)
        guard latch.admit(.automatic) else { return cachedEntry(store, profile, keyRejected: true) }
        do {
            let connection = try ServerConnection(profile: profile, secretStore: KeychainSecretStore(), liveTransport: URLSessionTransport(timeout: 12))
            let snapshot = try await HeadroomLoader.load(profile: profile, secret: connection.secret, transport: connection.transport)
            store.saveSnapshot(snapshot)
            return HeadroomEntry(date: .now, snapshot: snapshot, isStale: false)
        } catch {
            latch.record(APIError.wrapping(error))
            if latch.isBlocked && !profile.isDemo {
                store.saveAuthFailureLatch(latch, for: profile.id, generation: latchGeneration)
            }
            return cachedEntry(store, profile, keyRejected: latch.isBlocked)
        }
    }

    private func cachedEntry(_ store: ProfileStore, _ profile: ServerProfile, keyRejected: Bool) -> HeadroomEntry {
        let cached = store.loadSnapshot().flatMap { $0.serverID == profile.id ? $0 : nil }
        return HeadroomEntry(date: .now, snapshot: cached, isStale: true, keyRejected: keyRejected)
    }

    static let sample = HeadroomSnapshot(
        serverID: ServerProfile.demoID,
        serverName: "Demo server",
        isDemo: true,
        generatedAt: .now,
        source: .passiveObservations,
        providers: [
            ProviderHeadroom(provider: "claude", headroomPercent: 66, limitingBarID: "weekly_all", resetsAt: nil, usableCredentials: 2, totalCredentials: 3, bars: []),
            ProviderHeadroom(provider: "codex", headroomPercent: 29, limitingBarID: "weekly_all", resetsAt: nil, usableCredentials: 1, totalCredentials: 2, bars: []),
            ProviderHeadroom(provider: "gemini-cli", headroomPercent: nil, limitingBarID: nil, resetsAt: nil, usableCredentials: 1, totalCredentials: 2, bars: [])
        ]
    )
}

struct HeadroomWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "HeadroomWidget", intent: HeadroomWidgetIntent.self, provider: HeadroomTimelineProvider()) { entry in
            HeadroomWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(Text("Headroom"))
        .description(Text("Lowest remaining quota per provider on your default server."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct HeadroomWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HeadroomEntry

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            header
            if entry.keyRejected {
                Text("The server rejected the key. Open Proxy Gauge to fix it.")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if let snapshot = entry.snapshot {
                rows(snapshot)
            } else {
                Spacer(minLength: 0)
                Text("Open Proxy Gauge and choose a default server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .foregroundStyle(.tint)
            Group {
                if let snapshot = entry.snapshot, !snapshot.isDemo {
                    Text(verbatim: snapshot.serverName)
                } else {
                    Text("Demo server")
                }
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            Spacer(minLength: 0)
            if entry.keyRejected {
                Image(systemName: "key.slash")
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

    @ViewBuilder
    private func rows(_ snapshot: HeadroomSnapshot) -> some View {
        let limit = family == .systemSmall ? 3 : 4
        let providers = Array(snapshot.providers.sorted { ($0.headroomPercent ?? 101) < ($1.headroomPercent ?? 101) }.prefix(limit))
        if snapshot.source == .unavailable {
            Text("This server shares no quota with client keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if providers.isEmpty {
            Text("No accounts yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(providers) { provider in
            ProviderHeadroomRow(headroom: provider, compact: true)
        }
        Spacer(minLength: 0)
        if family == .systemMedium {
            Text("Updated \(Text(snapshot.generatedAt, style: .relative)) ago")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
