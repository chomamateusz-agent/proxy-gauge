import AppKit
import ProxyGaugeCore
import ProxyGaugeSession
import ProxyGaugeStore
import SwiftUI

struct RouterForkTransport: HTTPTransport {
    var strategy = RouterSettings.useOrLose
    private let demo = DemoTransport()

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.method == .get, request.url.path().hasSuffix("/v8/management/config/routing/strategy") {
            var response = HTTPResponse(statusCode: 200, body: Data("\"\(strategy)\"".utf8))
            response.setHeader("X-CPA-VERSION", "8.0.69-fleet.c41d9e07")
            return response
        }
        var response = try await demo.send(request)
        if response.header("X-CPA-VERSION") != nil {
            response.setHeader("X-CPA-VERSION", "8.0.69-fleet.c41d9e07")
        }
        return response
    }
}

@MainActor
enum PanelRenders {
    static let prefix = "fix-mac-"
    static let savedSuiteName = "proxygauge.render-tool.saved"

    static func run(model: AppModel, defaults: UserDefaults, output: URL) async throws {
        guard let demoProfile = model.defaultProfile else { return }
        let demo = model.session(for: demoProfile)
        await demo.refreshLimits(trigger: .manual, origin: .visibleApp)
        let fork = try await forkSession(strategy: RouterSettings.useOrLose)
        func file(_ name: String) -> URL { output.appending(path: "\(prefix)\(name).png") }
        if Renderer.rendersPolish {
            model.selectedSection = .overview
            try await Renderer.renderWindow(model: model, defaults: defaults, size: CGSize(width: 1440, height: 900), appearance: .aqua, to: file("overview-1440x900-light-pl"))
            let provider = MacRedesignRenders.window(model: model, defaults: defaults, profile: demoProfile) {
                ProviderDetailView(session: demo, provider: "claude")
            }
            try await Renderer.renderInWindow(provider, size: CGSize(width: 1100, height: 800), appearance: .darkAqua, to: file("provider-claude-1100x800-dark-pl"))
            model.selectedSection = .accounts
            try await Renderer.renderWindow(model: model, defaults: defaults, size: CGSize(width: 1440, height: 900), appearance: .darkAqua, to: file("accounts-1440x900-dark-pl"))
            try await Renderer.render(cardStrip(demo: demo), size: stripSize, appearance: .darkAqua, to: file("card-states-dark-pl"))
            return
        }
        for (sizeName, size) in MacRedesignRenders.sizes {
            for (scheme, appearance) in MacRedesignRenders.appearances {
                for (name, section) in [("overview", ServerSection.overview), ("accounts", .accounts)] {
                    model.selectedSection = section
                    try await Renderer.renderWindow(model: model, defaults: defaults, size: size, appearance: appearance, to: file("\(name)-\(sizeName)-\(scheme)"))
                }
                model.selectedSection = .overview
                let provider = MacRedesignRenders.window(model: model, defaults: defaults, profile: demoProfile) {
                    ProviderDetailView(session: demo, provider: "claude")
                }
                try await Renderer.renderInWindow(provider, size: size, appearance: appearance, to: file("provider-claude-\(sizeName)-\(scheme)"))
                let router = MacRedesignRenders.window(model: model, defaults: defaults, profile: demoProfile) {
                    OverviewView(session: fork)
                        .freshnessHeader(session: fork, scope: .accounts)
                }
                try await Renderer.renderInWindow(router, size: size, appearance: appearance, to: file("overview-router-order-\(sizeName)-\(scheme)"))
            }
        }
        let fillFirst = try await forkSession(strategy: "fill-first")
        let saved = savedSession(from: demo)
        for (scheme, appearance) in MacRedesignRenders.appearances {
            let listOrder = MacRedesignRenders.window(model: model, defaults: defaults, profile: demoProfile) {
                OverviewView(session: fillFirst)
                    .freshnessHeader(session: fillFirst, scope: .accounts)
            }
            try await Renderer.renderInWindow(listOrder, size: CGSize(width: 1440, height: 900), appearance: appearance, to: file("overview-fill-first-1440x900-\(scheme)"))
            let savedOverview = MacRedesignRenders.window(model: model, defaults: defaults, profile: demoProfile) {
                OverviewView(session: saved)
            }
            try await Renderer.renderInWindow(savedOverview, size: CGSize(width: 1100, height: 800), appearance: appearance, to: file("overview-saved-1100x800-\(scheme)"))
            try await Renderer.render(cardStrip(demo: demo), size: stripSize, appearance: appearance, to: file("card-states-\(scheme)"))
        }
        let now = Date.now
        if let cooling = demo.accountSummaries.first(where: { CardStatus(account: $0, now: now).isBlocked }) {
            for (scheme, appearance) in MacRedesignRenders.appearances {
                let popover = StatusPopover(account: cooling, session: demo, checkNow: {}, showResets: {})
                    .fixedSize()
                    .background(BoardStyle.cardBackground)
                try await Renderer.render(popover, size: CGSize(width: 340, height: 560), appearance: appearance, to: file("pill-popover-\(scheme)"))
            }
        }
    }

    static func forkSession(strategy: String) async throws -> ServerSession {
        let fork = Renderer.providerSession("Fork server", transport: RouterForkTransport(strategy: strategy))
        await fork.refresh(.accounts, trigger: .manual)
        await fork.refresh(.settings, trigger: .manual)
        await fork.refreshLimits(trigger: .manual, origin: .visibleApp)
        return fork
    }

    static func savedSession(from demo: ServerSession) -> ServerSession {
        let defaults = UserDefaults(suiteName: savedSuiteName)!
        defaults.removePersistentDomain(forName: savedSuiteName)
        let store = ProfileStore(defaults: defaults)
        let profile = ServerProfile(name: "Home server", baseURL: URL(string: "https://render.invalid")!, authMode: .management)
        let now = Date.now
        store.saveSnapshot(HeadroomSnapshot.management(profile, credentials: demo.credentials, active: demo.activeQuotas, generatedAt: now.addingTimeInterval(-2 * 3_600), now: now))
        return ServerSession(profile: profile, secrets: MemorySecretStore(), latchStore: store, transport: OfflineTransport(), refreshesAutomatically: false)
    }

    static let stripSize = CGSize(width: 1180, height: 440)

    static func cardStrip(demo: ServerSession) -> some View {
        let now = Date.now
        let accounts = demo.accountSummaries
        var failed = accounts.first { $0.provider == "claude" && CardStatus(account: $0, now: now) == .active } ?? accounts[0]
        var state = failed.providerCheckState ?? ActiveRefreshState()
        state.lastFailure = .upstream(status: 503)
        failed.providerCheckState = state
        let monthly = AccountSummary(id: "monthly", provider: "codex", label: "team@example.com", state: .active, plan: "team", bars: [
            QuotaBar(id: "session_5h", usedPercent: 12, resetsAt: now.addingTimeInterval(3 * 3_600)),
            QuotaBar(id: "window_43200m", usedPercent: 37, resetsAt: now.addingTimeInterval(19 * 86_400))
        ])
        let cooling = accounts.first { CardStatus(account: $0, now: now).isBlocked } ?? accounts[0]
        let capped = accounts.first { $0.provider == "claude" && $0.id != failed.id } ?? accounts[0]
        let cards: [(AccountSummary, RouterBadge?)] = [
            (failed, nil),
            (monthly, nil),
            (cooling, .listOrder),
            (capped, .ranked(position: 3, tier: .capped)),
            (failed, .listOrder)
        ]
        return HStack(alignment: .top, spacing: PanelStyle.cardSpacing) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                AccountQuotaCard(account: card.0, badge: card.1, session: demo)
                    .frame(width: 210)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BoardStyle.pageBackground)
    }
}
