import ProxyGaugeCore
import ProxyGaugeStore
import SwiftUI

enum EditorTarget: Identifiable {
    case add
    case edit(ServerProfile)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let profile): profile.id.uuidString
        }
    }
}

struct ServerEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let target: EditorTarget
    @State private var name = ""
    @State private var address = ""
    @State private var authMode: AuthMode = .management
    @State private var secret = ""
    @State private var probing = false
    @State private var report: ProbeReport?
    @State private var saveError: Error?
    @State private var saved = false
    @State private var saveTask: Task<Void, Never>?
    @State private var confirmingDeletion = false

    private var existing: ServerProfile? {
        if case .edit(let profile) = target { return profile }
        return nil
    }

    private var isDemo: Bool { existing?.isDemo ?? false }

    var body: some View {
        NavigationStack {
            Form {
                if isDemo {
                    demoSection
                } else {
                    connectionSection
                }
                if let report {
                    ProbeReportSection(report: report)
                    if !report.succeeded && !saved {
                        Section {
                            Button("Save anyway") { startSave(force: true) }
                        } footer: {
                            Text("Saves the server without a successful check, for example when it is offline right now.")
                        }
                    }
                }
                if let saveError {
                    Section { Text(saveError.userMessage).foregroundStyle(.red) }
                }
                if existing == nil && !model.showsDemo {
                    Section {
                        Button("Add demo server", systemImage: "play.rectangle") {
                            model.restoreDemo()
                            dismiss()
                        }
                    } footer: {
                        Text("The demo uses built-in sample data shaped like a real server. It makes no network requests.")
                    }
                }
                if existing != nil {
                    Section {
                        Button("Delete server", systemImage: "trash", role: .destructive) { confirmingDeletion = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? Text("Add server") : Text("Edit server"))
            .toolbar { toolbar }
            .disabled(probing)
            .interactiveDismissDisabled(probing)
            .onAppear(perform: load)
            .onDisappear { saveTask?.cancel() }
            .confirmationDialog(
                "Delete this server?",
                isPresented: $confirmingDeletion,
                titleVisibility: .visible,
                presenting: existing
            ) { profile in
                Button("Delete", role: .destructive) { delete(profile) }
            } message: { profile in
                ServerDeletionMessage(profile: profile)
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private var demoSection: some View {
        Section {
            Picker("Mode", selection: $authMode) {
                Text("Management key").tag(AuthMode.management)
                Text("Client key").tag(AuthMode.clientKey)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Demo server")
        } footer: {
            Text("The demo uses built-in sample data shaped like a real server. It makes no network requests.")
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            TextField("Name", text: $name, prompt: Text("Home server"))
                .accessibilityLabel(Text("Name"))
            TextField("Address", text: $address, prompt: Text(verbatim: "http://192.168.1.10:8317"))
                .accessibilityLabel(Text("Address"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
        } header: {
            Text("Server")
        } footer: {
            let normalized = BaseURLValidator.normalize(address)
            if case .failure(.hasUserInfo) = normalized {
                Text("Remove the user name and password from the address. Proxy Gauge only sends the key entered below.")
                    .foregroundStyle(.red)
            } else if case .success(let url) = normalized,
               ServerProfile(name: name, baseURL: url, authMode: authMode).usesPlainHTTPOutsideLocalNetwork {
                Text("Plain HTTP sends your key unencrypted over this route. Prefer HTTPS, or a private network such as Tailscale.")
                    .foregroundStyle(.orange)
            } else {
                Text("Include the port and any path prefix, for example https://proxy.example.com/cpa.")
            }
        }
        Section {
            Picker("Key type", selection: $authMode) {
                Text("Management key").tag(AuthMode.management)
                Text("Client key").tag(AuthMode.clientKey)
            }
            .pickerStyle(.segmented)
            SecureField("Key", text: $secret, prompt: existing == nil ? Text("Paste the key") : Text("Leave empty to keep the stored key"))
                .accessibilityLabel(Text("Key"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } header: {
            Text("Access")
        } footer: {
            authMode == .management
                ? Text("The management key (management.secret-key) unlocks accounts, usage and settings. For remote access the server needs management.allow-remote: true.")
                : Text("A client key (from access.api-keys) shows models and, on servers that offer /v1/fleet/limits, quota bars. It cannot change anything.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { saved ? Text("Done") : Text("Cancel") }
        }
        ToolbarItem(placement: .confirmationAction) {
            if probing {
                ProgressView()
            } else if !saved {
                Button { startSave(force: false) } label: { isDemo ? Text("Save") : Text("Check and save") }
                    .disabled(!isDemo && !canSave)
            }
        }
    }

    private var canSave: Bool {
        guard case .success = BaseURLValidator.normalize(address) else { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && (existing != nil || !secret.isEmpty)
    }

    private func load() {
        guard let existing else { return }
        name = existing.name
        address = existing.baseURL.absoluteString
        authMode = existing.authMode
    }

    private func startSave(force: Bool) {
        saveTask?.cancel()
        saveTask = Task { await checkAndSave(force: force) }
    }

    private func checkAndSave(force: Bool) async {
        saveError = nil
        if let existing, existing.isDemo {
            var profile = existing
            profile.authMode = authMode
            persist(profile, secret: nil)
            if saveError == nil { dismiss() }
            return
        }
        guard case .success(let url) = BaseURLValidator.normalize(address) else { return }
        let profile = ServerProfile(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            baseURL: url,
            authMode: authMode
        )
        if !force {
            let candidateSecret: String
            do {
                guard let found = secret.isEmpty ? try existingSecret(for: profile) : secret else {
                    saveError = APIError.missingCredential
                    return
                }
                candidateSecret = found
            } catch {
                saveError = error
                return
            }
            probing = true
            let result = await ServerProbe.run(baseURL: url, authMode: authMode, secret: candidateSecret, transport: URLSessionTransport(timeout: 10))
            probing = false
            guard !Task.isCancelled else { return }
            report = result
            guard result.succeeded else { return }
        }
        guard !Task.isCancelled else { return }
        persist(profile, secret: secret.isEmpty ? nil : secret, pausedBy: force ? report?.failure?.authPauseReason : nil)
    }

    private func delete(_ profile: ServerProfile) {
        do {
            try model.delete(profile)
            dismiss()
        } catch {
            saveError = error
        }
    }

    private func existingSecret(for profile: ServerProfile) throws -> String? {
        guard existing != nil else { return nil }
        return try model.secrets.secret(for: profile.id)
    }

    private func persist(_ profile: ServerProfile, secret: String?, pausedBy pauseReason: AuthPauseReason? = nil) {
        do {
            try model.save(profile, secret: secret, pausedBy: pauseReason)
            self.secret = ""
            saved = true
            if report == nil || report?.succeeded == false {
                dismiss()
            }
        } catch {
            saveError = error
        }
    }
}

struct ProbeReportSection: View {
    let report: ProbeReport

    var body: some View {
        Section {
            if let failure = report.failure {
                Label {
                    Text(failure.userMessage)
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            } else {
                Label("Connected", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            if let version = report.version {
                LabeledContent("Version") { Text(verbatim: version.version) }
            }
            if let accounts = report.accountCount {
                LabeledContent("Accounts") { Text(accounts, format: .number) }
            }
            if let models = report.modelCount {
                LabeledContent("Models") { Text(models, format: .number) }
            }
            ForEach(report.checkedFeatures, id: \.feature) { item in
                LabeledContent {
                    Image(systemName: item.available ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(item.available ? .green : .secondary)
                        .accessibilityLabel(item.available ? Text("Available") : Text("Not available"))
                } label: {
                    Text(item.feature.label)
                }
            }
        } header: {
            Text("What the server answered")
        }
    }
}

extension ServerFeature {
    var label: LocalizedStringResource {
        switch self {
        case .health: "Health check (/healthz, informational)"
        case .managementAPI: "Management API v8"
        case .routingSettings: "Routing strategy"
        case .clientKeyUsageReport: "Client-key token report"
        case .clientModels: "Model list (/v1/models)"
        case .fleetLimits: "Quota for client keys (/v1/fleet/limits)"
        }
    }
}
