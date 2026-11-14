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
    static func color(forHeadroom headroom: Double?) -> Color {
        guard let headroom else { return .secondary }
        switch headroom {
        case ..<15: return .red
        case ..<40: return .orange
        default: return .green
        }
    }

    static func color(forUsed used: Double?) -> Color {
        color(forHeadroom: used.map { 100 - $0 })
    }

    static func percentText(_ value: Double?) -> String {
        guard let value else { return "–" }
        return (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}

extension QuotaWindow {
    var label: LocalizedStringResource {
        switch self {
        case .session5h: "5-hour"
        case .weekly: "Weekly"
        case .weeklyModel: "Weekly (model)"
        case .daily: "Daily"
        case .minutes(let minutes): "\(minutes)-minute window"
        case .other(let id): LocalizedStringResource(stringLiteral: id)
        }
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

struct UsageBar: View {
    let usedPercent: Double?
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(1, max(0, (usedPercent ?? 0) / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if usedPercent != nil {
                    Capsule()
                        .fill(HeadroomStyle.color(forUsed: usedPercent).gradient)
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
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: headroom.provider, size: compact ? 20 : 28)
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ProviderCatalog.displayName(headroom.provider))
                        .font(compact ? .caption.weight(.semibold) : .headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(HeadroomStyle.percentText(headroom.headroomPercent))
                        .font(compact ? .caption.monospacedDigit().weight(.semibold) : .headline.monospacedDigit())
                        .foregroundStyle(HeadroomStyle.color(forHeadroom: headroom.headroomPercent))
                }
                UsageBar(usedPercent: headroom.headroomPercent.map { 100 - $0 }, height: compact ? 5 : 8)
                if !compact {
                    detail
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var detail: some View {
        if headroom.headroomPercent == nil {
            Text("No quota data reported yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let barID = headroom.limitingBarID {
            Group {
                if let resetsAt = headroom.resetsAt, resetsAt > .now {
                    Text("Limited by \(Text(QuotaWindow(barID: barID).label)) · resets in \(Text(resetsAt, style: .relative))")
                } else {
                    Text("Limited by \(Text(QuotaWindow(barID: barID).label))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
