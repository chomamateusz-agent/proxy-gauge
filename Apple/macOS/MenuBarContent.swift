import AppKit
import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.session(for: model.defaultProfile)
        let lowest = session.headroom.compactMap(\.headroomPercent).min()
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.50percent")
            if let lowest {
                Text(HeadroomStyle.percentText(lowest)).monospacedDigit()
            }
        }
        .task(id: model.refreshInterval) {
            while !Task.isCancelled {
                await model.refreshDefaultHeadroom(trigger: .automatic)
                try? await Task.sleep(for: .seconds(model.refreshInterval))
            }
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let profile = model.defaultProfile
        let session = model.session(for: profile)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DisplayName(profile: profile).font(.headline)
                if profile.isDemo { DemoBadge() }
                Spacer()
                RefreshFooter(lastRefresh: session.lastRefresh, isRefreshing: session.isRefreshing)
            }
            if let error = session.failure(for: session.headroomScope) {
                Text(error.userMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let reason = session.pauseReason {
                Text(reason.pausedNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let headroom = session.headroom
            if headroom.isEmpty {
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
            ForEach(headroom) { provider in
                ProviderHeadroomRow(headroom: provider)
            }
            let pools = session.pools.filter { !$0.windows.isEmpty }
            if !pools.isEmpty {
                Divider()
                Text("Pooled capacity")
                    .font(.subheadline.weight(.semibold))
                ForEach(pools) { pool in
                    PooledProviderRow(pool: pool, compact: true)
                }
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
        .frame(width: 320)
    }
}
