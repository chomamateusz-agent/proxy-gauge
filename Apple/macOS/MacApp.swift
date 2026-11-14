import ProxyGaugeCore
import SwiftUI

@main
struct MacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window(Text("Proxy Gauge"), id: MainWindow.id) {
            RootView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1080, height: 700)

        Settings {
            AppSettingsView()
                .environment(model)
                .frame(width: 460)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

enum MainWindow {
    static let id = "main"
}
