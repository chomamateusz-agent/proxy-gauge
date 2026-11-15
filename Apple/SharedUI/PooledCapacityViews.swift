import ProxyGaugeCore
import SwiftUI

extension PooledWindow {
    var remainingShareOfCapacity: Double? {
        capacityPercent > 0 && knownAccounts > 0 ? min(1, max(0, remainingPercent / capacityPercent)) : nil
    }

    var amountText: Text {
        Text("\(HeadroomStyle.percentText(remainingPercent)) of \(HeadroomStyle.percentText(capacityPercent))")
    }

    var color: Color {
        HeadroomStyle.color(forRemaining: remainingShareOfCapacity.map { $0 * 100 })
    }

    func dataSampledAt(snapshotTakenAt generatedAt: Date) -> Date {
        min(generatedAt, latestSampleAt ?? generatedAt)
    }
}

struct PooledCapacityBar: View {
    let window: PooledWindow
    var height: CGFloat = 8

    var body: some View {
        RemainingBar(remainingPercent: window.remainingShareOfCapacity.map { $0 * 100 }, height: height)
    }
}

struct PooledWindowRow: View {
    let window: PooledWindow
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack(alignment: .firstTextBaseline) {
                window.title
                    .font(compact ? .caption2 : .subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                window.amountText
                    .font(compact ? .caption2.monospacedDigit().weight(.semibold) : .subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(window.color)
            }
            PooledCapacityBar(window: window, height: compact ? 4 : 6)
            if !compact {
                PooledWindowNotes(window: window)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PooledWindowNotes: View {
    let window: PooledWindow

    var body: some View {
        if window.unknownAccounts > 0 || window.accountsWithoutRunningWindow > 0 || window.nextIncreaseAt.map({ $0 > .now }) == true {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { notes }
                VStack(alignment: .leading, spacing: 2) { notes }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var notes: some View {
        if window.unknownAccounts > 0 {
            Text("Accounts without data: \(window.unknownAccounts)")
        }
        if window.accountsWithoutRunningWindow > 0 {
            Text("No 5-hour window: \(window.accountsWithoutRunningWindow)")
        }
        if let next = window.nextIncreaseAt, next > .now {
            Text("More in \(Text(next, style: .relative))")
        }
    }
}

struct PooledProviderRow: View {
    let pool: ProviderPool
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(spacing: 10) {
                ProviderBadge(provider: pool.provider, size: compact ? 20 : 28)
                Text(ProviderCatalog.displayName(pool.provider))
                    .font(compact ? .caption.weight(.semibold) : .headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                AccountCountText(pool: pool)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if pool.windows.isEmpty {
                Group {
                    if pool.accounts == 0 {
                        Text("Every account of this provider is disabled.")
                    } else {
                        Text("No quota data reported yet")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(pool.windows) { window in
                PooledWindowRow(window: window, compact: compact)
            }
        }
    }
}

struct AccountCountText: View {
    let pool: ProviderPool

    var body: some View {
        Text("Accounts: \(pool.totalAccounts) · usable: \(pool.usableAccounts)")
    }
}

extension Array where Element == ProviderPool {
    func primary(_ provider: String?) -> ProviderPool? {
        first { $0.provider == provider } ?? PooledCapacity.mostConstrained(self)
    }
}
