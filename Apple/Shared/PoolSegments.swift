import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct StatusChipView: View {
    let chip: StatusChip

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: symbol)
                .imageScale(.small)
        }
        .labelStyle(.titleAndIcon)
        .font(.board(.caption).weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: .capsule)
        .fixedSize()
    }

    private var text: Text {
        switch chip.kind {
        case .state(.active): Text("\(chip.count) active")
        case .state(.cooldown): Text("\(chip.count) cooling down")
        case .state(.disabled): Text("\(chip.count) disabled")
        case .state(.error): Text("\(chip.count) error")
        case .needsSignIn: Text("\(chip.count) needs sign-in")
        }
    }

    private var color: Color {
        switch chip.kind {
        case .state(let state): state.color
        case .needsSignIn: .red
        }
    }

    private var symbol: String {
        switch chip.kind {
        case .state(let state): state.symbol
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        }
    }
}

struct StatusChipRow: View {
    let chips: [StatusChip]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(chips, id: \.self) { StatusChipView(chip: $0) }
        }
    }
}

struct ComebackFooter: View {
    let overview: ProviderOverview

    var body: some View {
        if let comeback = overview.comeback {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: comeback.kind.symbol)
                    .foregroundStyle(comeback.kind.tint)
                    .accessibilityHidden(true)
                Text(verbatim: OverviewWording.lead(comeback))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let gains = OverviewWording.gains(comeback, in: overview.pool) {
                    Text(verbatim: gains)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.board(.footnote))
            .accessibilityElement(children: .combine)
        } else if let next = overview.pool.nextIncreaseAt, next > .now {
            Label {
                Text("More at \(ResetClock.text(next))")
            } icon: {
                Image(systemName: "clock")
            }
            .font(.board(.footnote))
            .foregroundStyle(.secondary)
        }
    }
}

extension ServerSession {
    func cardOrderMode(routerOrder: Bool) -> CardOrderMode {
        guard supportsRouterOrder, routerOrder, let routerSettings else { return .stock }
        return .router(routerSettings)
    }

    func orderedAccounts(provider: String?, routerOrder: Bool, now: Date) -> [OrderedAccount] {
        let accounts = accountSummaries.filter { provider == nil || $0.provider == provider }
        return AccountOrder.ordered(accounts, mode: cardOrderMode(routerOrder: routerOrder), now: now)
    }
}

extension CardOrderMode {
    var caption: LocalizedStringResource {
        switch self {
        case .stock: "Usable first"
        case .router(let settings): settings.ranksByUseOrLose ? "Router order" : "List order"
        }
    }
}

struct RouterOrderStorage: DynamicProperty {
    @AppStorage private var stored: Bool

    init(serverID: UUID) {
        _stored = AppStorage(wrappedValue: ServerLab.routerOrderDefault, ServerLab.routerOrderKey(serverID: serverID))
    }

    var isOn: Bool { stored }

    var binding: Binding<Bool> { $stored }
}
