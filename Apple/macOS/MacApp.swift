import ProxyGaugeCore
import SwiftUI

@main
struct MacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window(Text("Proxy Gauge"), id: MainWindow.id) {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 560)
        }
        .defaultSize(width: 1440, height: 900)
        .commands { PaneRefreshCommands() }

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

struct PaneRefreshCommands: Commands {
    @FocusedValue(\.paneRefresh) private var pane

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Refresh") { pane?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(pane == nil || pane?.isRefreshing == true)
            Button("Check limits with providers…") { pane?.checkLimits?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(pane?.checkLimits == nil || pane?.checkingLimits == true)
            Divider()
        }
    }
}
