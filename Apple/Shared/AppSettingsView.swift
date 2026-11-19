import ProxyGaugeCore
import ProxyGaugeStore
import SwiftUI

struct AppSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(OverviewLayout.storageKey) private var storedOverviewLayout = OverviewLayout.standard.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Overview layout", selection: Binding(
                    get: { OverviewLayout.resolve(storedOverviewLayout) },
                    set: { storedOverviewLayout = $0.rawValue }
                )) {
                    ForEach(OverviewLayout.allCases) { layout in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(layout.title)
                            Text(layout.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tag(layout)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Overview")
            }
            Section {
                Picker("Refresh every", selection: Binding(get: { model.settings.refreshInterval }, set: { model.setRefreshInterval($0) })) {
                    ForEach(StoredSettings.refreshIntervalChoices, id: \.self) { interval in
                        Text(Duration.seconds(interval), format: .units(allowed: [.minutes, .seconds], width: .wide)).tag(interval)
                    }
                }
                ForEach(model.profiles) { profile in
                    Toggle(isOn: Binding(get: { model.refreshesAutomatically(profile) }, set: { model.setRefreshesAutomatically($0, for: profile) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Refresh automatically")
                            DisplayName(profile: profile)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Auto refresh")
            } footer: {
                Text("Proxy Gauge refreshes only the screen you are looking at, and only while the app is open. It reads what the proxy already knows; asking the providers directly is the separate setting below. With automatic refresh off for a server, the app, the menu bar and the widget do not refresh it on their own: the widget shows the last saved values with their age, and refreshing by hand always works.")
            }
            Section {
                let managed = model.profiles.filter { $0.authMode == .management }
                if managed.isEmpty {
                    Text("Only servers added with a management key can ask providers for limits.")
                        .foregroundStyle(.secondary)
                }
                ForEach(managed) { profile in
                    Toggle(isOn: Binding(get: { model.refreshesLimitsFromProviders(profile) }, set: { model.setRefreshesLimitsFromProviders($0, for: profile) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Refresh limits from providers automatically")
                            DisplayName(profile: profile)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.refreshesLimitsFromProviders(profile) {
                        Picker("Check every", selection: Binding(get: { model.providerRefreshInterval(profile) }, set: { model.setProviderRefreshInterval($0, for: profile) })) {
                            ForEach(ActiveRefreshPolicy.automaticIntervalChoices, id: \.self) { interval in
                                Text(Duration.seconds(interval), format: .units(allowed: [.minutes], width: .wide)).tag(interval)
                            }
                        }
                    }
                }
            } header: {
                Text("Limits from providers")
            } footer: {
                Text("Off by default. While Proxy Gauge is visible on screen and automatic refresh is on, the server checks Claude, Codex, Kimi and Devin accounts with their providers at this interval: Claude at most every 30 minutes, plans at most once a day. xAI and Google accounts, reset grants and reset credits are checked only when you choose Refresh limits. The widget and the menu bar never contact providers, and rate limits from a provider pause the checks for that account.")
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
