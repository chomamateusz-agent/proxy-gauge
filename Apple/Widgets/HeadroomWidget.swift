import AppIntents
import ProxyGaugeCore
import ProxyGaugeStore
import SwiftUI
import WidgetKit

@main
struct ProxyGaugeWidgets: WidgetBundle {
    var body: some Widget {
        HeadroomWidget()
        PooledCapacityWidget()
    }
}

struct HeadroomWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Headroom"
    static let description = IntentDescription("Quota left on the best single account per provider on your default server.")
}

struct HeadroomEntry: TimelineEntry {
    var date: Date
    var snapshot: HeadroomSnapshot?
    var isStale: Bool
    var showsSavedAge = false
    var pauseReason: AuthPauseReason?
    var link: URL?
}

struct HeadroomTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> HeadroomEntry {
        HeadroomEntry(date: .now, snapshot: Self.sample, isStale: false)
    }

    func snapshot(for configuration: HeadroomWidgetIntent, in context: Context) async -> HeadroomEntry {
        if context.isPreview {
            return placeholder(in: context)
        }
        return await entries().first ?? placeholder(in: context)
    }

    func timeline(for configuration: HeadroomWidgetIntent, in context: Context) async -> Timeline<HeadroomEntry> {
        Timeline(entries: await entries(), policy: .after(.now.addingTimeInterval(WidgetRefreshPolicy.interval)))
    }

    private func entries() async -> [HeadroomEntry] {
        guard let (profile, refreshesAutomatically) = WidgetData.profile(nil) else {
            return [HeadroomEntry(date: .now, snapshot: nil, isStale: false)]
        }
        let link = WidgetData.overviewLink(profile)
        let entries = await WidgetData.timeline(for: profile, refreshesAutomatically: refreshesAutomatically) { date, result in
            HeadroomEntry(
                date: date,
                snapshot: result.snapshot,
                isStale: result.isStale,
                showsSavedAge: result.origin == .saved,
                pauseReason: result.pauseReason,
                link: link
            )
        }
        return Array(entries.prefix(1))
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
                .widgetURL(entry.link)
        }
        .configurationDisplayName(Text("Headroom"))
        .description(Text("Quota left on the best single account per provider on your default server."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct HeadroomWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HeadroomEntry

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            header
            if let reason = entry.pauseReason {
                Text(reason.widgetNote)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if let snapshot = entry.snapshot {
                rows(snapshot)
            } else {
                Spacer(minLength: 0)
                Group {
                    if entry.showsSavedAge {
                        Text("Automatic refresh is off. Refresh in Proxy Gauge to save values.")
                    } else {
                        Text("Open Proxy Gauge and choose a default server.")
                    }
                }
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

    @ViewBuilder
    private func rows(_ snapshot: HeadroomSnapshot) -> some View {
        let limit = family == .systemSmall ? 3 : 4
        let providers = Array(snapshot.headroom(at: entry.date).sorted { ($0.headroomPercent ?? 101) < ($1.headroomPercent ?? 101) }.prefix(limit))
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
            ProviderHeadroomRow(headroom: provider)
        }
        Spacer(minLength: 0)
        if entry.showsSavedAge {
            Text("Saved \(Text(snapshot.generatedAt, style: .relative)) ago")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if family == .systemMedium {
            Text("Updated \(Text(snapshot.generatedAt, style: .relative)) ago")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

extension AuthPauseReason {
    var widgetNote: LocalizedStringResource {
        switch self {
        case .keyRejected: "The server rejected the key. Open Proxy Gauge to fix it."
        case .ipBanned: "The server has temporarily blocked this network address. Open Proxy Gauge to retry later."
        }
    }
}
