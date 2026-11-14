import Charts
import ProxyGaugeCore
import SwiftUI

struct UsageView: View {
    let session: ServerSession

    var body: some View {
        let summary = session.usageSummary
        List {
            SessionStatusSection(session: session)
            Section {
                HStack(spacing: 12) {
                    StatTile(title: "Requests", value: summary.total)
                    StatTile(title: "Failed", value: summary.failed, tint: summary.failed > 0 ? .red : .secondary)
                }
                if let rate = summary.failureRate {
                    LabeledContent("Failure rate") {
                        Text(rate, format: .percent.precision(.fractionLength(1)))
                    }
                }
            } header: {
                Text("Requests")
            } footer: {
                if session.keyCountersError != nil {
                    Text("Counted by the proxy since it started. The upstream API-key counters could not be refreshed, so their share may be out of date.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Counted by the proxy since it started, across accounts and upstream API keys.")
                }
            }
            if !summary.buckets.isEmpty {
                Section("Last 200 minutes") {
                    RecentRequestsChart(buckets: summary.buckets)
                        .frame(height: 180)
                        .padding(.vertical, 4)
                }
            }
            Section("Requests per provider") {
                ForEach(summary.providers) { provider in
                    HStack {
                        ProviderBadge(provider: provider.provider, size: 22)
                        Text(ProviderCatalog.displayName(provider.provider))
                        Spacer()
                        Text(provider.total, format: .number).monospacedDigit()
                        if provider.failed > 0 {
                            Text("(\(provider.failed) failed)")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            tokenSection
        }
    }

    @ViewBuilder
    private var tokenSection: some View {
        if let usage = session.tokenUsage {
            Section {
                HStack(spacing: 12) {
                    StatTile(title: "Tokens", value: usage.totals.totalTokens)
                    StatTile(title: "Output", value: usage.totals.outputTokens)
                }
                if !usage.models.isEmpty {
                    Chart(usage.models.prefix(8)) { model in
                        BarMark(x: .value("Tokens", model.counters.totalTokens), y: .value("Model", model.model))
                            .foregroundStyle(ProviderStyle.color(model.provider).gradient)
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let tokens = value.as(Int64.self) {
                                    Text(tokens, format: .number.notation(.compactName))
                                }
                            }
                        }
                    }
                    .frame(height: CGFloat(max(2, min(8, usage.models.count))) * 34)
                }
                ForEach(usage.models) { model in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(verbatim: model.model).font(.callout.monospaced())
                            Spacer()
                            Text(model.counters.totalTokens, format: .number.notation(.compactName)).monospacedDigit()
                        }
                        Text("\(model.counters.requests) requests · \(ProviderCatalog.displayName(model.provider))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Tokens per model, last 7 days")
            } footer: {
                Text("From the server's client-key usage report.")
            }
        } else if session.tokenUsageLoaded {
            Section("Tokens") {
                Text("This server does not keep a token report. Stock CLIProxyAPI only exposes a one-shot usage queue, which Proxy Gauge leaves alone so it does not take records from other tools.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatTile: View {
    let title: LocalizedStringResource
    let value: Int64
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value, format: .number.notation(.compactName))
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
