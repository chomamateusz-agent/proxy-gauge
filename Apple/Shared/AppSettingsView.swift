import ProxyGaugeCore
import ProxyGaugeStore
import SwiftUI

struct AppSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Refresh every", selection: Binding(get: { model.settings.refreshInterval }, set: { model.setRefreshInterval($0) })) {
                    ForEach(StoredSettings.refreshIntervalChoices, id: \.self) { interval in
                        Text(Duration.seconds(interval), format: .units(allowed: [.minutes, .seconds], width: .wide)).tag(interval)
                    }
                }
            } header: {
                Text("Auto refresh")
            } footer: {
                Text("Proxy Gauge refreshes only the screen you are looking at, and only while the app is open. It reads what the proxy already knows and never asks providers for quota.")
            }
            Section("Privacy") {
                Text("Keys stay in the Keychain on this device. Proxy Gauge talks only to the servers you add. No analytics, no tracking, no accounts.")
                    .font(.callout)
            }
            Section("About") {
                LabeledContent("Version") { Text(verbatim: "\(AppVersion.marketing) (\(AppVersion.build))") }
                Link(destination: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!) {
                    Label("About CLIProxyAPI", systemImage: "arrow.up.right.square")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Settings"))
    }
}
