import ProxyGaugeCore
import SwiftUI

extension PooledWindow {
    var remainingShareOfCapacity: Double? {
        share(of: remainingPercent)
    }

    var usableShareOfCapacity: Double? {
        share(of: usablePercent)
    }

    private func share(of percent: Double) -> Double? {
        capacityPercent > 0 && knownAccounts > 0 ? min(1, max(0, percent / capacityPercent)) : nil
    }

    var amountText: Text {
        Text("\(HeadroomStyle.percentText(remainingPercent)) of \(HeadroomStyle.percentText(capacityPercent))")
    }

    var color: Color {
        HeadroomStyle.color(forRemaining: usableShareOfCapacity.map { $0 * 100 })
    }

    var usableNowText: Text {
        Text("Usable now: \(HeadroomStyle.percentText(usablePercent))")
    }

    var blockedText: Text {
        let usable = HeadroomStyle.percentText(usablePercent)
        let blocked = HeadroomStyle.percentText(blockedPercent)
        let reason = blockReason.map(\.text) ?? Text(verbatim: "")
        guard let blockedUntil else {
            return Text("Usable now: \(usable) · \(blocked) blocked (\(reason))")
        }
        let back = ResetClock.text(blockedUntil)
        if blockClearsAtOnce {
            return Text("Usable now: \(usable) · \(blocked) blocked (\(reason)) · back \(back)")
        }
        let clearingFirst = HeadroomStyle.percentText(blockedPercentClearingFirst)
        return Text("Usable now: \(usable) · \(blocked) blocked (\(reason)) · \(clearingFirst) back \(back)")
    }

    func dataSampledAt(snapshotTakenAt generatedAt: Date) -> Date {
        min(generatedAt, latestSampleAt ?? generatedAt)
    }
}

extension PoolAccount.Block.Reason {
    var text: Text {
        switch self {
        case .cooldown: Text("cooldown")
        case .signIn: Text("needs a new sign-in")
        case .windowAtLimit(let barID):
            switch QuotaWindow(barID: barID) {
            case .session5h: Text("5-hour limit")
            case .daily: Text("daily limit")
            case .monthly: Text("monthly limit")
            case .weekly: Text("weekly limit")
            default: Text("window limit")
            }
        }
    }
}

struct PooledCapacityBar: View {
    let window: PooledWindow
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let usable = proxy.size.width * (window.usableShareOfCapacity ?? 0)
            let blocked = proxy.size.width * max(0, (window.remainingShareOfCapacity ?? 0) - (window.usableShareOfCapacity ?? 0))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(window.color.gradient)
                        .frame(width: usable)
                    BlockedStripes(color: window.color)
                        .frame(width: blocked)
                }
                .clipShape(.capsule)
                .frame(width: max(usable + blocked, usable + blocked > 0 ? height : 0), alignment: .leading)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct BlockedStripes: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.22)))
            var stripes = Path()
            let spacing: CGFloat = 5
            var x = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(stripes, with: .color(color.opacity(0.55)), lineWidth: 1.5)
        }
    }
}

struct PooledWindowRow: View {
    enum BlockedLine {
        case full
        case usableOnly
    }

    let window: PooledWindow
    var compact = false
    var blockedLine = BlockedLine.full

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
            if window.hasBlockedQuota {
                switch blockedLine {
                case .full:
                    window.blockedText
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                case .usableOnly:
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) {
                            window.usableNowText
                                .foregroundStyle(.orange)
                            idleNote
                        }
                        window.usableNowText
                            .foregroundStyle(.orange)
                    }
                    .font(.caption2)
                    .lineLimit(1)
                }
            }
            if !compact {
                PooledWindowNotes(window: window)
            } else if blockedLine == .full {
                if window.accountsCountedAsFull > 0 {
                    Text("incl. \(window.accountsCountedAsFull) idle account at 100%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !window.hasBlockedQuota {
                idleNote
                    .font(.caption2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var idleNote: some View {
        if window.accountsCountedAsFull > 0 {
            Text("+\(window.accountsCountedAsFull) idle")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("incl. \(window.accountsCountedAsFull) idle account at 100%"))
        }
    }
}

struct PooledWindowNotes: View {
    let window: PooledWindow

    var body: some View {
        if window.unknownAccounts > 0 || window.accountsCountedAsFull > 0 || window.accountsWithoutRunningWindow > 0 || window.nextIncreaseAt.map({ $0 > .now }) == true {
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
        if window.accountsCountedAsFull > 0 {
            Text("\(window.accountsCountedAsFull) account has no 5-hour window running, counted as full")
        }
        if window.accountsWithoutRunningWindow > 0 {
            Text("Blocked with no 5-hour window, left out: \(window.accountsWithoutRunningWindow)")
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
