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
                MenuBarServerSummary(session: model.session(for: profile), refreshesAutomatically: model.refreshesAutomatically(profile))
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
                Button("Reload from API", systemImage: "arrow.clockwise") {
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
        .frame(width: MenuBarStyle.width)
    }
}

enum MenuBarStyle {
    static let width: CGFloat = 360
    static let maxPoolsHeight: CGFloat = 560
}

struct MenuBarServerSummary: View {
    let session: ServerSession
    let refreshesAutomatically: Bool

    var body: some View {
        let profile = session.profile
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
        if !refreshesAutomatically {
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
        } else {
            let accounts = session.accountSummaries
            CappedScrollView(maxHeight: MenuBarStyle.maxPoolsHeight) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(quota.pools) { pool in
                        VStack(alignment: .leading, spacing: 6) {
                            PooledProviderRow(pool: pool, compact: true)
                            if let headroom = quota.headroom.first(where: { $0.provider == pool.provider }), headroom.isWorthShowingBesideThePool {
                                BestAccountLine(headroom: headroom, compact: true)
                            }
                            MenuBarAccountList(accounts: accounts.filter { $0.provider == pool.provider })
                        }
                    }
                }
            }
        }
    }
}

struct CappedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}

struct MenuBarAccountList: View {
    let accounts: [AccountSummary]

    var body: some View {
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(accounts) { account in
                    MenuBarAccountRow(account: account)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
    }
}

struct MenuBarAccountRow: View {
    let account: AccountSummary

    var body: some View {
        let now = Date.now
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: account.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: account.label))
                Spacer(minLength: 4)
                if let until = account.block(at: now)?.until {
                    Text("until \(ResetClock.text(until))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                StateChip(state: account.state)
            }
            if account.bars.isEmpty {
                Group {
                    if account.state == .disabled {
                        Text("Disabled, not counted")
                    } else {
                        Text("No quota data reported yet")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 1) {
                    ForEach(account.bars) { bar in
                        MenuBarWindowRow(bar: bar, now: now)
                    }
                }
            }
        }
        .opacity(account.state == .disabled ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

private struct MenuBarWindowRow: View {
    let bar: QuotaBar
    let now: Date

    var body: some View {
        let remaining = bar.remainingPercent(at: now)
        GridRow {
            bar.title
                .foregroundStyle(.secondary)
            Text(HeadroomStyle.percentText(remaining))
                .monospacedDigit()
                .fontWeight(.semibold)
                .foregroundStyle(remaining == nil ? .secondary : HeadroomStyle.color(forRemaining: remaining))
                .gridColumnAlignment(.trailing)
            Group {
                if let resetsAt = bar.resetsAt, resetsAt > now {
                    Text("resets \(ResetClock.text(resetsAt))")
                } else if bar.hasReset(at: now) {
                    Text("reset passed")
                }
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .lineLimit(1)
    }
}
