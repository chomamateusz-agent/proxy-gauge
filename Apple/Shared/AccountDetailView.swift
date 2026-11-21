import Charts
import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

struct AccountDetailView: View {
    let session: ServerSession
    let credentialID: Credential.ID

    @State private var pendingAction: PendingAction?
    @State private var actionError: Error?
    @State private var working = false

    enum PendingAction: Identifiable {
        case disable
        case enable
        case resetCooldown

        var id: Self { self }
    }

    var body: some View {
        if let credential = session.credential(id: credentialID) {
            content(credential)
        } else {
            ContentUnavailableView("Account not found", systemImage: "person.crop.circle.badge.xmark", description: Text("It may have been removed on the server."))
        }
    }

    private func content(_ credential: Credential) -> some View {
        let now = Date.now
        let state = credential.state(at: now)
        return List {
            if let actionError {
                Section { Text(actionError.userMessage).foregroundStyle(.red) }
            }
            Section {
                HStack(spacing: 12) {
                    ProviderBadge(provider: credential.provider, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: credential.displayName)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(ProviderCatalog.displayName(credential.provider)).font(.subheadline).foregroundStyle(.secondary)
                        StateBadge(state: state)
                    }
                }
                if let message = credential.statusMessage, !message.isEmpty {
                    Text(verbatim: message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            quotaSection(credential)
            providerSection(credential)
            cooldownSection(credential, now: now)
            Section("Requests") {
                LabeledContent("Succeeded") { Text(credential.success, format: .number) }
                LabeledContent("Failed") { Text(credential.failed, format: .number) }
                if !credential.recentRequests.isEmpty {
                    RecentRequestsChart(buckets: UsageSummary.mergedBuckets([credential.recentRequests]))
                        .frame(height: 120)
                }
            }
            Section("Details") {
                LabeledContent("File") { Text(verbatim: credential.name).lineLimit(1) }
                if let label = credential.label, !label.isEmpty {
                    LabeledContent("Label") { Text(verbatim: label) }
                }
                if let projectID = credential.projectID {
                    LabeledContent("Project") { Text(verbatim: projectID) }
                }
                if let priority = credential.priority {
                    LabeledContent("Priority") { Text(priority, format: .number) }
                }
                if let lastRefresh = credential.lastRefresh {
                    LabeledContent("Token refreshed") { Text(lastRefresh, format: .relative(presentation: .named)) }
                }
            }
            Section("Models") {
                if let models = session.accountModels[credential.name] {
                    if models.isEmpty {
                        Text("No models registered for this account.").foregroundStyle(.secondary)
                    }
                    ForEach(models) { model in
                        Text(verbatim: model.id).font(.callout.monospaced())
                    }
                } else if session.accountModelsFailed.contains(credential.name) || session.isAutomaticRefreshPaused {
                    Text("The models of this account could not be read.").foregroundStyle(.secondary)
                } else if !session.refreshesAutomatically {
                    ManualRefreshHint()
                } else {
                    ProgressView()
                }
            }
            Section {
                Button(credential.disabled ? "Enable account" : "Disable account", systemImage: credential.disabled ? "play.circle" : "pause.circle") {
                    pendingAction = credential.disabled ? .enable : .disable
                }
                .disabled(working)
                if credential.authIndex != nil {
                    Button("Reset cooldown", systemImage: "arrow.counterclockwise") {
                        pendingAction = .resetCooldown
                    }
                    .disabled(working || credential.activeCooldowns(at: now).isEmpty)
                }
            } footer: {
                Text("Reset cooldown clears the proxy's local routing block only. It does not reset the provider's quota or spend credits.")
            }
        }
        .navigationTitle(Text(verbatim: credential.displayName))
        .task(id: credential.name) {
            await session.refresh(.accountModels(credential.name), trigger: .automatic)
        }
        .refreshable {
            await session.refreshAccountDetail(credential.name)
        }
        #if os(iOS)
        .freshnessHeader(session: session, scope: .accounts, credentialIDs: [credential.id]) {
            await session.refreshAccountDetail(credential.name)
        }
        #else
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await session.refreshAccountDetail(credential.name) }
                }
                .disabled(session.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
            }
            if session.supportsLimitsRefresh {
                ToolbarItem(placement: .primaryAction) {
                    RefreshLimitsButton(session: session, credentialIDs: [credential.id])
                }
            }
        }
        #endif
        .confirmationDialog(
            Text(confirmationTitle),
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            Button(role: action == .disable ? .destructive : nil) {
                perform(action, on: credential)
            } label: {
                Text(confirmationButton(action))
            }
        } message: { action in
            Text(confirmationMessage(action))
        }
    }

    private var notCheckedYet: Text {
        #if os(iOS)
        Text("Not checked with the provider yet. Hold Refresh and choose Check limits with providers to ask the provider for this account's current limits, plan and resets.")
        #else
        Text("Not checked with the provider yet. Refresh limits asks the provider for this account's current limits, plan and resets.")
        #endif
    }

    @ViewBuilder
    private func providerSection(_ credential: Credential) -> some View {
        if let account = session.accountSummaries.first(where: { $0.id == credential.id }), session.supportsLimitsRefresh {
            Section {
                if account.providerCheck == nil && account.providerCheckState == nil {
                    notCheckedYet
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let plan = account.providerCheck?.plan {
                    LabeledContent("Plan") { PlanChip(plan: plan) }
                }
                if let until = account.providerCheck?.planActiveUntil {
                    LabeledContent("Plan active until") { Text(until, format: .dateTime.month().day().year()) }
                }
                ProviderCheckNotes(account: account, showsCheckTime: false)
                    .font(.callout)
                if session.refreshingLimits.contains(credential.id) {
                    ProgressView()
                }
                Text("Bars marked with \(Image(systemName: "antenna.radiowaves.left.and.right")) come from the provider; the others come from what the proxy saw in traffic. For each window the newer reading wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Provider")
            }
        }
    }

    @ViewBuilder
    private func quotaSection(_ credential: Credential) -> some View {
        let bars = session.quotaBars(for: credential)
        Section {
            if bars.isEmpty {
                Text("This provider has not reported quota headers yet.").foregroundStyle(.secondary)
            }
            ForEach(bars) { bar in
                QuotaBarRow(bar: bar, provider: credential.provider)
            }
        } header: {
            Text("Quota")
        } footer: {
            QuotaSourcesLine(
                trafficSampledAt: bars.filter { !$0.isFromProvider }.compactMap(\.sampledAt).max(),
                providerCheckedAt: session.activeQuotas[credential.stableID]?.observedAt
            )
        }
    }

    @ViewBuilder
    private func cooldownSection(_ credential: Credential, now: Date) -> some View {
        let cooldowns = credential.activeCooldowns(at: now)
        if !cooldowns.isEmpty {
            Section("Cooldowns") {
                ForEach(cooldowns, id: \.self) { cooldown in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: cooldown.modelKey ?? String(localized: "Whole account"))
                            .font(.callout.weight(.medium))
                        HStack {
                            Text(verbatim: cooldown.reason)
                            if let status = cooldown.httpStatus {
                                Text(verbatim: "HTTP \(status)")
                            }
                            Spacer()
                            if let retryAt = cooldown.retryAt {
                                Text(retryAt, style: .relative)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var confirmationTitle: LocalizedStringResource {
        switch pendingAction {
        case .disable: "Disable this account?"
        case .enable: "Enable this account?"
        case .resetCooldown, nil: "Reset the cooldown?"
        }
    }

    private func confirmationButton(_ action: PendingAction) -> LocalizedStringResource {
        switch action {
        case .disable: "Disable"
        case .enable: "Enable"
        case .resetCooldown: "Reset cooldown"
        }
    }

    private func confirmationMessage(_ action: PendingAction) -> LocalizedStringResource {
        switch action {
        case .disable: "The proxy stops routing requests to this account until you enable it again."
        case .enable: "The proxy starts routing requests to this account again."
        case .resetCooldown: "The proxy will try this account again right away. If the provider still limits it, it will cool down again."
        }
    }

    private func perform(_ action: PendingAction, on credential: Credential) {
        working = true
        actionError = nil
        Task {
            defer { working = false }
            do {
                switch action {
                case .disable: try await session.setDisabled(true, credential: credential)
                case .enable: try await session.setDisabled(false, credential: credential)
                case .resetCooldown: try await session.resetCooldown(credential)
                }
            } catch {
                actionError = error
            }
        }
    }
}

struct RecentRequestsChart: View {
    @Environment(\.locale) private var locale
    let buckets: [UsageBucket]

    var body: some View {
        Chart {
            ForEach(buckets) { bucket in
                BarMark(x: .value("Time", bucket.index), y: .value("Requests", bucket.success))
                    .foregroundStyle(by: .value("Result", String(localized: "Succeeded")))
                BarMark(x: .value("Time", bucket.index), y: .value("Requests", bucket.failed))
                    .foregroundStyle(by: .value("Result", String(localized: "Failed")))
            }
        }
        .chartForegroundStyleScale([String(localized: "Succeeded"): Color.green, String(localized: "Failed"): Color.red])
        .chartXAxis {
            AxisMarks(values: axisValues) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let index = value.as(Int.self), buckets.indices.contains(index) {
                        Text(verbatim: buckets[index].startClockLabel(locale: locale))
                    }
                }
            }
        }
        .accessibilityLabel(Text("Requests in the last 200 minutes"))
    }

    private var axisValues: [Int] {
        guard buckets.count > 1 else { return buckets.map(\.index) }
        let step = max(1, buckets.count / 4)
        return Array(stride(from: 0, to: buckets.count, by: step))
    }
}

private struct QuotaSourcesLine: View {
    let trafficSampledAt: Date?
    let providerCheckedAt: Date?

    var body: some View {
        if trafficSampledAt != nil || providerCheckedAt != nil {
            TimelineView(.periodic(from: .now, by: 10)) { context in
                line(at: context.date)
            }
        }
    }

    private func line(at now: Date) -> Text {
        let traffic = trafficSampledAt.map { ElapsedTime.text(from: $0, to: now) }
        let provider = providerCheckedAt.map { ElapsedTime.text(from: $0, to: now) }
        return switch (traffic, provider) {
        case let (traffic?, provider?): Text("From proxy traffic \(traffic) ago · checked with the provider \(provider) ago")
        case let (traffic?, nil): Text("From proxy traffic \(traffic) ago")
        case let (nil, provider?): Text("Checked with the provider \(provider) ago")
        case (nil, nil): Text(verbatim: "")
        }
    }
}
