import AppKit
import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

enum MainWindow {
    static let id = "main"
}

private struct MenuBarRefreshID: Hashable {
    var serverID: UUID?
    var interval: TimeInterval
    var refreshesAutomatically: Bool
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.50percent")
            if let profile = model.defaultProfile,
               let lowest = model.session(for: profile).quotaOverview(at: .now).lowestHeadroom {
                Text(HeadroomStyle.percentText(lowest)).monospacedDigit()
            }
        }
        .task(id: refreshID) {
            await AutoRefreshLoop.run(
                refreshesAutomatically: refreshID.refreshesAutomatically,
                interval: refreshID.interval
            ) {
                await model.refreshDefaultHeadroom(trigger: .automatic)
            }
        }
    }

    private var refreshID: MenuBarRefreshID {
        let profile = model.defaultProfile
        return MenuBarRefreshID(
            serverID: profile?.id,
            interval: model.refreshInterval,
            refreshesAutomatically: profile.map(model.refreshesAutomatically) ?? false
        )
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let profile = model.defaultProfile {
                content(profile)
            } else {
                Text("Add a server in Proxy Gauge to see its quota here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Open Proxy Gauge") {
                    openWindow(id: MainWindow.id)
                    NSApp.activate()
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshDefaultHeadroom(trigger: .manual) }
                }
                .labelStyle(.iconOnly)
                .disabled(model.defaultProfile == nil)
                Button("Settings", systemImage: "gearshape") {
                    openSettings()
                    NSApp.activate()
                }
                .labelStyle(.iconOnly)
                Button("Quit", systemImage: "power") {
                    NSApp.terminate(nil)
                }
                .labelStyle(.iconOnly)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder
    private func content(_ profile: ServerProfile) -> some View {
        let session = model.session(for: profile)
        let quota = session.quotaOverview(at: .now)
        HStack {
            DisplayName(profile: profile).font(.headline)
            if profile.isDemo { DemoBadge() }
            Spacer()
            if let savedAt = quota.savedAt {
                ElapsedText(since: savedAt) { Text("Saved \($0) ago") }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                RefreshFooter(lastRefresh: session.lastRefresh, isRefreshing: session.isRefreshing)
            }
        }
        if let error = session.failure(for: session.headroomScope) {
            Text(error.userMessage)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let reason = session.pauseReason {
            Text(reason.pausedNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !model.refreshesAutomatically(profile) {
            Label("Automatic refresh is off", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if quota.pools.isEmpty {
            Group {
                if profile.authMode == .clientKey && session.limitsLoaded {
                    Text("This server shares no quota with client keys.")
                } else {
                    Text("No quota data yet.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        ForEach(quota.pools) { pool in
            VStack(alignment: .leading, spacing: 6) {
                PooledProviderRow(pool: pool, compact: true)
                if let headroom = quota.headroom.first(where: { $0.provider == pool.provider }), headroom.isWorthShowingBesideThePool {
                    BestAccountLine(headroom: headroom, compact: true)
                }
            }
        }
    }
}
