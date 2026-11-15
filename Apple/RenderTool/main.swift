import AppKit
import ProxyGaugeCore
import ProxyGaugeSession
import ProxyGaugeStore
import SwiftUI

final class MemorySecretStore: SecretStore {
    func secret(for serverID: UUID) throws -> String? { "render" }
    func setSecret(_ secret: String, for serverID: UUID) throws {}
    func deleteSecret(for serverID: UUID) throws {}
}

final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class EightAccountsTransport: HTTPTransport {
    private let demo = DemoTransport()

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var response = try await demo.send(request)
        guard request.url.path().hasSuffix("/v8/management/credentials"),
              var object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let files = object["files"] as? [[String: Any]]
        else { return response }
        let extra = files.filter { ($0["provider"] as? String) != "gemini-cli" }.prefix(2).enumerated().map { offset, original in
            var copy = original
            let name = "extra-\(offset + 1)"
            copy["id"] = name
            copy["name"] = name + ".json"
            copy["auth_index"] = "ff\(offset)"
            copy["email"] = "\(name)@example.com"
            return copy
        }
        object["files"] = files + extra
        response.body = try JSONSerialization.data(withJSONObject: object)
        return response
    }
}

struct OfflineTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw APIError.transport("render tool is offline")
    }
}

// cacheDisplay drops the system switch's on-state fill, so the settings render draws the state itself.
struct CapturableSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Capsule()
                .fill(configuration.isOn ? Color.accentColor : Color.secondary.opacity(0.3))
                .frame(width: 38, height: 22)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .padding(2)
                        .shadow(radius: 0.5)
                }
        }
    }
}

struct RenderScene {
    var name: String
    var section: ServerSection
    var layout: AccountsLayout
}

@MainActor
enum Renderer {
    static let suiteName = "proxygauge.render-tool"
    static let renderLocale = Locale(identifier: "en_US")
    static let sizes: [(name: String, size: CGSize)] = [("1920x1080", CGSize(width: 1920, height: 1080)), ("1440x900", CGSize(width: 1440, height: 900))]
    static let scenes = [
        RenderScene(name: "overview", section: .overview, layout: .cards),
        RenderScene(name: "accounts-cards", section: .accounts, layout: .cards),
        RenderScene(name: "accounts-list", section: .accounts, layout: .list),
        RenderScene(name: "accounts-table", section: .accounts, layout: .table)
    ]

    static func run(output: URL) async throws {
        guard Locale.current.decimalSeparator == renderLocale.decimalSeparator else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "run with -AppleLocale en_US so formatted numbers match the English renders"])
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(store: ProfileStore(defaults: defaults), secrets: MemorySecretStore())
        guard let demo = model.defaultProfile else { throw CocoaError(.featureUnsupported) }
        model.select(demo)
        await model.session(for: demo).refresh(.accounts, trigger: .manual)
        try await renderExtras(model: model, defaults: defaults, output: output)
        for scene in scenes {
            defaults.set(scene.layout.rawValue, forKey: AccountsLayout.storageKey)
            model.selectedSection = scene.section
            for (sizeName, size) in sizes {
                for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                    let scheme = appearance == .darkAqua ? "dark" : "light"
                    let file = output.appending(path: "mac-\(scene.name)-\(sizeName)-\(scheme).png")
                    try await renderWindow(model: model, defaults: defaults, size: size, appearance: appearance, to: file)
                    print(file.path)
                }
            }
        }
    }

    static func renderExtras(model: AppModel, defaults: UserDefaults, output: URL) async throws {
        defaults.set(AccountsLayout.cards.rawValue, forKey: AccountsLayout.storageKey)
        let eight = ServerProfile(name: "Eight accounts", baseURL: URL(string: "https://render.invalid")!, authMode: .management)
        let session = ServerSession(profile: eight, secrets: MemorySecretStore(), latchStore: nil, transport: EightAccountsTransport())
        await session.refresh(.accounts, trigger: .manual)
        let longURL = ServerProfile(name: "Workstation", baseURL: URL(string: "https://workstation-012.sample-tailnet.example.com:8317/cpa")!, authMode: .management)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let scheme = appearance == .darkAqua ? "dark" : "light"
            let overview = NavigationStack { OverviewView(session: session) }.environment(model).defaultAppStorage(defaults)
            try await render(overview, size: CGSize(width: 1440, height: 1028), appearance: appearance, to: output.appending(path: "mac-overview-8-accounts-detail-1440x1028-\(scheme).png"))
            let sidebar = List {
                ServerRow(profile: longURL, isDefault: true)
                ServerRow(profile: .demo(), isDefault: false)
            }
            try await render(sidebar, size: CGSize(width: 260, height: 200), appearance: appearance, to: output.appending(path: "mac-sidebar-rows-260-\(scheme).png"))
            let menu = MenuBarContent().environment(model)
            try await render(menu, size: CGSize(width: 340, height: 560), appearance: appearance, to: output.appending(path: "mac-menubar-\(scheme).png"))
            let footnotes = DashboardFootnotes().padding().frame(width: 440)
            try await render(footnotes, size: CGSize(width: 440, height: 400), appearance: appearance, to: output.appending(path: "mac-footnotes-popover-\(scheme).png"))
        }
        try await renderFiveWindows(model: model, defaults: defaults, output: output)
        try await renderSavedWhileOff(model: model, defaults: defaults, output: output)
        try await renderProviderRefresh(model: model, defaults: defaults, output: output)
    }

    static func providerSession(_ name: String, transport: any HTTPTransport) -> ServerSession {
        let profile = ServerProfile(name: name, baseURL: URL(string: "https://render.invalid")!, authMode: .management)
        let store = MemoryActiveRefreshStore()
        return ServerSession(
            profile: profile,
            secrets: MemorySecretStore(),
            latchStore: nil,
            transport: transport,
            coordinator: ActiveRefreshCoordinator(store: store, pause: { _ in }),
            activeStore: store
        )
    }

    static func renderProviderRefresh(model: AppModel, defaults: UserDefaults, output: URL) async throws {
        let planned = providerSession("Provider plan", transport: ProviderRenderTransport(addsGoogleAndKimi: true))
        await planned.refresh(.accounts, trigger: .manual)
        let refreshed = providerSession("Provider results", transport: ProviderRenderTransport())
        await refreshed.refreshLimits(trigger: .manual, origin: .visibleApp)
        let notLoaded = providerSession("Not loaded", transport: ProviderRenderTransport())
        guard let demo = model.defaultProfile else { return }
        let clientKey = ServerSession(profile: .demo(authMode: .clientKey), secrets: MemorySecretStore(), latchStore: nil)
        await clientKey.refresh(.limits, trigger: .manual)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let scheme = appearance == .darkAqua ? "dark" : "light"
            let sheet = LimitsRefreshSheet(session: planned, credentialIDs: nil).environment(model)
            try await renderInWindow(sheet, size: CGSize(width: 560, height: 1180), appearance: appearance, to: output.appending(path: "mac-refresh-limits-sheet-560x1180-\(scheme).png"))
            let single = LimitsRefreshSheet(session: refreshed, credentialIDs: [ProviderRenderTransport.rateLimitedAuthIndex, "a1f3c9"]).environment(model)
            try await renderInWindow(single, size: CGSize(width: 560, height: 720), appearance: appearance, to: output.appending(path: "mac-refresh-limits-sheet-waiting-560x720-\(scheme).png"))
            let loadFirst = LimitsRefreshSheet(session: notLoaded, credentialIDs: nil).environment(model)
            try await renderInWindow(loadFirst, size: CGSize(width: 560, height: 620), appearance: appearance, to: output.appending(path: "mac-refresh-limits-sheet-load-accounts-560x620-\(scheme).png"))
            defaults.set(AccountsLayout.cards.rawValue, forKey: AccountsLayout.storageKey)
            let overview = NavigationStack { OverviewView(session: refreshed) }.environment(model).defaultAppStorage(defaults)
            try await render(overview, size: CGSize(width: 1440, height: 1300), appearance: appearance, to: output.appending(path: "mac-overview-provider-results-1440x1300-\(scheme).png"))
            defaults.set(AccountsLayout.table.rawValue, forKey: AccountsLayout.storageKey)
            let table = NavigationStack { AccountsView(session: refreshed) }.environment(model).defaultAppStorage(defaults)
            try await render(table, size: CGSize(width: 1400, height: 1000), appearance: appearance, to: output.appending(path: "mac-accounts-table-provider-results-1400x1000-\(scheme).png"))
            defaults.set(AccountsLayout.cards.rawValue, forKey: AccountsLayout.storageKey)
            let detail = NavigationStack { AccountDetailView(session: refreshed, credentialID: "a1f3c9") }.environment(model).defaultAppStorage(defaults)
            try await render(detail, size: CGSize(width: 720, height: 1300), appearance: appearance, to: output.appending(path: "mac-account-detail-provider-720x1300-\(scheme).png"))
            model.setRefreshesLimitsFromProviders(true, for: demo)
            let settings = AppSettingsView().toggleStyle(CapturableSwitchStyle()).environment(model).frame(width: 460)
            try await render(settings, size: CGSize(width: 460, height: 1100), appearance: appearance, to: output.appending(path: "mac-settings-provider-refresh-460x1100-\(scheme).png"))
            model.setRefreshesLimitsFromProviders(false, for: demo)
            let client = NavigationStack { ClientLimitsView(session: clientKey) }.environment(model).defaultAppStorage(defaults)
            try await render(client, size: CGSize(width: 940, height: 420), appearance: appearance, to: output.appending(path: "mac-client-limits-note-940x420-\(scheme).png"))
        }
    }

    static func renderFiveWindows(model: AppModel, defaults: UserDefaults, output: URL) async throws {
        let profile = ServerProfile(name: "Five windows", baseURL: URL(string: "https://render.invalid")!, authMode: .management)
        let session = ServerSession(profile: profile, secrets: MemorySecretStore(), latchStore: nil, transport: FiveWindowsTransport())
        await session.refresh(.accounts, trigger: .manual)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let scheme = appearance == .darkAqua ? "dark" : "light"
            defaults.set(AccountsLayout.table.rawValue, forKey: AccountsLayout.storageKey)
            for width in [940, 1400] {
                let table = NavigationStack { AccountsView(session: session) }.environment(model).defaultAppStorage(defaults)
                try await render(table, size: CGSize(width: CGFloat(width), height: 900), appearance: appearance, to: output.appending(path: "mac-accounts-table-5-windows-detail-\(width)x900-\(scheme).png"))
            }
            defaults.set(AccountsLayout.cards.rawValue, forKey: AccountsLayout.storageKey)
            let overview = NavigationStack { OverviewView(session: session) }.environment(model).defaultAppStorage(defaults)
            try await render(overview, size: CGSize(width: 1400, height: 1300), appearance: appearance, to: output.appending(path: "mac-overview-5-windows-detail-1400x1300-\(scheme).png"))
        }
    }

    static func renderSavedWhileOff(model: AppModel, defaults: UserDefaults, output: URL) async throws {
        let store = ProfileStore(defaults: defaults)
        let profile = ServerProfile(name: "Workstation", baseURL: URL(string: "https://workstation-012.sample-tailnet.example.com:8317")!, authMode: .management)
        let loader = ServerSession(profile: profile, secrets: MemorySecretStore(), latchStore: nil, transport: DemoTransport())
        await loader.refresh(.accounts, trigger: .manual)
        var saved = HeadroomSnapshot.management(profile, credentials: loader.credentials, now: .now)
        saved.generatedAt = Date.now.addingTimeInterval(-42 * 60)
        store.saveSnapshot(saved)
        let session = ServerSession(profile: profile, secrets: MemorySecretStore(), latchStore: store, transport: OfflineTransport(), refreshesAutomatically: false)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let scheme = appearance == .darkAqua ? "dark" : "light"
            let overview = NavigationStack { OverviewView(session: session) }.environment(model).defaultAppStorage(defaults)
            try await render(overview, size: CGSize(width: 940, height: 900), appearance: appearance, to: output.appending(path: "mac-overview-saved-refresh-off-detail-940x900-\(scheme).png"))
            let accounts = NavigationStack { AccountsView(session: session) }.environment(model).defaultAppStorage(defaults)
            try await render(accounts, size: CGSize(width: 940, height: 400), appearance: appearance, to: output.appending(path: "mac-accounts-refresh-off-detail-940x400-\(scheme).png"))
        }
        store.forgetServer(profile.id)
    }

    static func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to file: URL) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top).environment(\.locale, renderLocale))
        let window = UnconstrainedWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -30_000, y: -30_000))
        window.orderBack(nil)
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
        }
        try snapshot(hosting, dark: appearance == .darkAqua).write(to: file)
        print(file.path)
        window.orderOut(nil)
        window.close()
    }

    static func renderWindow(model: AppModel, defaults: UserDefaults, size: CGSize, appearance: NSAppearance.Name, to file: URL) async throws {
        let root = RootView()
            .environment(model)
            .defaultAppStorage(defaults)
        try await renderInWindow(root, size: size, appearance: appearance, to: file)
    }

    static func renderInWindow(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to file: URL) async throws {
        let hosting = NSHostingView(rootView: view.environment(\.locale, renderLocale))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = UnconstrainedWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.setContentSize(size)
        window.setFrameOrigin(CGPoint(x: -30_000, y: -30_000))
        window.orderBack(nil)
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
        }
        let frameView = hosting.superview ?? hosting
        try snapshot(frameView, dark: appearance == .darkAqua).write(to: file)
        window.orderOut(nil)
        window.close()
    }
}

extension Renderer {
    static func snapshot(_ view: NSView, dark: Bool) throws -> Data {
        let bounds = view.bounds
        guard let cached = view.bitmapImageRepForCachingDisplay(in: bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: bounds, to: cached)
        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: output) else { throw CocoaError(.fileWriteUnknown) }
        output.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        CGRect(origin: .zero, size: bounds.size).fill()
        cached.draw(in: CGRect(origin: .zero, size: bounds.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = output.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return png
    }
}

final class RenderDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath)
        Task { @MainActor in
            do {
                try await Renderer.run(output: output)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }
}

let application = NSApplication.shared
let delegate = RenderDelegate()
application.delegate = delegate
application.setActivationPolicy(.prohibited)
application.run()
