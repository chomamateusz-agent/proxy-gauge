import ProxyGaugeCore
import SwiftUI

enum ProviderStyle {
    static func color(_ provider: String) -> Color {
        switch provider.lowercased() {
        case "claude": .orange
        case "codex": .teal
        case "gemini", "gemini-cli", "vertex", "aistudio": .blue
        case "antigravity": .purple
        case "kimi": .indigo
        case "qwen": .pink
        case "devin": .mint
        default: .gray
        }
    }

    static func symbol(_ provider: String) -> String {
        switch provider.lowercased() {
        case "claude": "sparkle"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "gemini", "gemini-cli", "vertex", "aistudio": "diamond.fill"
        case "antigravity": "arrow.up.circle.fill"
        case "openai-compatibility", "openai": "point.3.connected.trianglepath.dotted"
        default: "server.rack"
        }
    }
}

enum HeadroomStyle {
    static func color(forRemaining remaining: Double?) -> Color {
        guard let remaining else { return .secondary }
        switch remaining {
        case ..<30: return .red
        case ..<70: return .orange
        default: return .green
        }
    }

    static var track: Color {
        #if os(macOS)
        Color.secondary.opacity(0.2)
        #else
        Color(uiColor: .tertiarySystemFill)
        #endif
    }

    static func percentText(_ value: Double?) -> String {
        guard let value else { return "–" }
        return (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    static func remainingText(_ remaining: Double?) -> Text {
        guard remaining != nil else { return Text("Unknown") }
        return Text("\(percentText(remaining)) left")
    }
}

extension QuotaWindow {
    var label: LocalizedStringResource {
        switch self {
        case .session5h: "5-hour"
        case .weekly: "Weekly"
        case .weeklyFable: "Weekly Fable"
        case .weeklyModel: "Weekly (\(modelDisplayName ?? ""))"
        case .daily: "Daily"
        case .monthly: "Monthly"
        case .minutes(let minutes): "\(minutes)-minute window"
        case .other(let id): LocalizedStringResource(stringLiteral: id)
        }
    }
}

extension QuotaBar {
    var title: Text {
        label.map { Text(verbatim: $0) } ?? Text(window.label)
    }
}

extension PooledWindow {
    var title: Text {
        label.map { Text(verbatim: $0) } ?? Text(window.label)
    }
}

extension CredentialState {
    var label: LocalizedStringResource {
        switch self {
        case .active: "Active"
        case .cooldown: "Cooldown"
        case .disabled: "Disabled"
        case .error: "Error"
        }
    }

    var color: Color {
        switch self {
        case .active: .green
        case .cooldown: .orange
        case .disabled: .gray
        case .error: .red
        }
    }

    var symbol: String {
        switch self {
        case .active: "checkmark.circle.fill"
        case .cooldown: "hourglass"
        case .disabled: "pause.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

enum ResetClock {
    static func format(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Date.FormatStyle {
        if calendar.isDate(date, inSameDayAs: now) {
            return .dateTime.hour().minute()
        }
        if abs(date.timeIntervalSince(now)) < 6 * 86_400 {
            return .dateTime.weekday(.abbreviated).hour().minute()
        }
        return .dateTime.month(.abbreviated).day().hour().minute()
    }

    static func text(_ date: Date) -> Text {
        Text(date, format: format(date))
    }

    static func string(_ date: Date, now: Date = .now) -> String {
        date.formatted(format(date, now: now))
    }
}

struct ProviderBadge: View {
    let provider: String
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: ProviderStyle.symbol(provider))
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(ProviderStyle.color(provider).gradient, in: .rect(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

struct RemainingBar: View {
    let remainingPercent: Double?
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(1, max(0, (remainingPercent ?? 0) / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(HeadroomStyle.track)
                if let remainingPercent, remainingPercent > 0 {
                    Capsule()
                        .fill(HeadroomStyle.color(forRemaining: remainingPercent).gradient)
                        .frame(width: max(height, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct ProviderHeadroomRow: View {
    let headroom: ProviderHeadroom

    var body: some View {
        HStack(spacing: 8) {
            ProviderBadge(provider: headroom.provider, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ProviderCatalog.displayName(headroom.provider))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(HeadroomStyle.percentText(headroom.headroomPercent))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(HeadroomStyle.color(forRemaining: headroom.headroomPercent))
                        .accessibilityHidden(true)
                }
                RemainingBar(remainingPercent: headroom.headroomPercent, height: 5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(HeadroomStyle.remainingText(headroom.headroomPercent))
    }
}

struct BestAccountLine: View {
    let headroom: ProviderHeadroom
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Best usable account")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                HeadroomStyle.remainingText(headroom.headroomPercent)
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(HeadroomStyle.color(forRemaining: headroom.headroomPercent))
            }
            .font(compact ? .caption2 : .subheadline)
            detail
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var detail: some View {
        if headroom.usableCredentials == 0 && headroom.totalCredentials > 0 {
            Text("No account can take requests right now")
        } else if headroom.headroomPercent == nil {
            Text("No quota data reported yet")
        } else if let barID = headroom.limitingBarID {
            if let resetsAt = headroom.resetsAt, resetsAt > .now {
                Text("Limited by \(Text(QuotaWindow(barID: barID).label)) · resets in \(Text(resetsAt, style: .relative))")
            } else {
                Text("Limited by \(Text(QuotaWindow(barID: barID).label))")
            }
        }
    }
}

extension AuthPauseReason {
    var symbol: String {
        switch self {
        case .keyRejected: "key.slash"
        case .ipBanned: "exclamationmark.shield"
        }
    }

    var widgetNote: LocalizedStringResource {
        switch self {
        case .keyRejected: "The server rejected the key. Open Proxy Gauge to fix it."
        case .ipBanned: "The server has temporarily blocked this network address. Open Proxy Gauge to retry later."
        }
    }
}
