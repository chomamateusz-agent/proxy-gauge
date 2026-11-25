import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

extension QuotaWindow {
    var shortLabel: LocalizedStringResource {
        switch self {
        case .session5h: LocalizedStringResource("gain.five-hour", defaultValue: "5-hour")
        case .weekly: "weekly"
        case .weeklyModel: LocalizedStringResource(stringLiteral: modelDisplayName ?? "")
        case .daily: "daily"
        case .monthly: "monthly"
        case .minutes(let minutes): "\(minutes)-minute window"
        case .other(let id): LocalizedStringResource(stringLiteral: id)
        }
    }
}

enum OverviewWording {
    static func names(_ names: [String]) -> String {
        names.count <= ProviderOverview.namedAccountsLimit
            ? names.formatted(.list(type: .and))
            : String(localized: "\(names.count) accounts")
    }

    static func windowName(_ barID: String, in pool: ProviderPool) -> String {
        pool.windows.first { $0.barID == barID }?.label ?? String(localized: QuotaWindow(barID: barID).shortLabel)
    }

    static func gains(_ comeback: Comeback, in pool: ProviderPool) -> String? {
        let parts = comeback.gains.map { gain in
            String(localized: "+\(HeadroomStyle.percentText(gain.percent)) \(windowName(gain.barID, in: pool))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func lead(_ comeback: Comeback) -> String {
        let who = names(comeback.accounts)
        switch comeback.kind {
        case .accountsBack:
            guard let at = comeback.at else { return String(localized: "\(who) blocked, no end time reported") }
            return String(localized: "\(who): back at \(ResetClock.string(at))")
        case .windowsReset:
            guard let at = comeback.at else { return who }
            return String(localized: "\(who): reset at \(ResetClock.string(at))")
        case .needsSignIn:
            return String(localized: "\(who) needs a new sign-in")
        case .blockedWithoutEnd:
            return String(localized: "\(who) blocked, no end time reported")
        }
    }
}

extension Comeback.Kind {
    var symbol: String {
        switch self {
        case .accountsBack, .blockedWithoutEnd: "hourglass"
        case .windowsReset: "clock"
        case .needsSignIn: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .accountsBack, .blockedWithoutEnd: .orange
        case .windowsReset: .secondary
        case .needsSignIn: .red
        }
    }
}

struct NoQuotaDataReason: View {
    let overview: ProviderOverview
    let canRefreshLimits: Bool

    var body: some View {
        Label {
            text.fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
    }

    private var signIn: [String] { overview.accountsNeedingSignIn }

    private var fetchable: Bool {
        canRefreshLimits && ActiveRefreshPolicy.isSupported(overview.pool.provider)
    }

    private var text: Text {
        if overview.pool.accounts == 0 {
            Text("Every account of this provider is disabled.")
        } else if !signIn.isEmpty {
            Text(verbatim: String(localized: "\(OverviewWording.names(signIn)) needs a new sign-in"))
        } else if fetchable {
            Text("Choose Refresh from provider to load quota")
        } else {
            Text("No quota data reported yet")
        }
    }

    private var symbol: String {
        if overview.pool.accounts == 0 { return "pause.circle" }
        if !signIn.isEmpty { return "exclamationmark.triangle.fill" }
        return fetchable ? "arrow.triangle.2.circlepath.circle" : "questionmark.circle"
    }

    private var tint: Color {
        signIn.isEmpty ? .secondary : .red
    }
}
