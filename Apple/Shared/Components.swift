import ProxyGaugeCore
import ProxyGaugeSession
import ProxyGaugeStore
import SwiftUI

extension APIError {
    var userMessage: LocalizedStringResource {
        switch self {
        case .invalidBaseURL:
            "The server address is not valid."
        case .missingCredential:
            "No key is stored for this server. Edit the server to add one."
        case .credentialUnavailable(let detail):
            "The key could not be read from the Keychain right now (\(detail)). Try again in a moment."
        case .unauthorized(let message):
            if let message { "The server rejected the key: \(message)" } else { "The server rejected the key." }
        case .forbidden(let message):
            if isRemoteManagementDisabled {
                "Remote management is disabled on this server. Set management.allow-remote to true in its config."
            } else if let message {
                "Access denied: \(message)"
            } else {
                "Access denied."
            }
        case .ipBanned(let retryAt):
            if let retryAt, retryAt > .now {
                "The server has temporarily blocked this network address after too many failed key attempts from it, possibly by another client. It accepts keys again at \(retryAt.formatted(date: .omitted, time: .shortened))."
            } else {
                "The server has temporarily blocked this network address after too many failed key attempts from it, possibly by another client. Try again later."
            }
        case .notFound:
            "The server does not offer this endpoint (HTTP 404). Management may be disabled or the address may include the wrong path."
        case .conflict(let message):
            "The server reported a conflict: \(message ?? "")"
        case .preconditionFailed:
            "The configuration changed on the server in the meantime. The current value is shown now; try again if you still want the change."
        case .server(let status, let message):
            "Server error \(status): \(message ?? "")"
        case .decoding(let detail):
            "Unexpected response from the server (\(detail))."
        case .transport(let detail):
            "Could not reach the server: \(detail)"
        case .pausedBeforeSending(.keyRejected):
            "The change was not sent because the server rejected the key while it was waiting. Refresh to check the key, then try the change again."
        case .pausedBeforeSending(.ipBanned):
            "The change was not sent because the server blocked this network address while it was waiting. Refresh once the block ends, then try the change again."
        }
    }
}

extension Error {
    var userMessage: LocalizedStringResource {
        if let keychainError = self as? SecretStoreError {
            return switch keychainError.operation {
            case .read: APIError.credentialUnavailable(keychainError.description).userMessage
            case .save: "The key could not be saved to the Keychain right now (\(keychainError.description)). Try again in a moment."
            case .delete: "The key could not be removed from the Keychain right now (\(keychainError.description)). Try again in a moment."
            }
        }
        return APIError.wrapping(self).userMessage
    }
}

struct NotLoadedRow: View {
    let phase: LoadPhase

    var body: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .unavailable:
            Text("Not loaded. See the message above.")
                .foregroundStyle(.secondary)
        case .lastAttemptFailed:
            Text("Not loaded. Refresh to try again.")
                .foregroundStyle(.secondary)
        case .waitingForManualRefresh:
            ManualRefreshHint()
        case .loaded:
            EmptyView()
        }
    }
}

extension AuthPauseReason {
    var pausedNote: LocalizedStringResource {
        switch self {
        case .keyRejected:
            "Automatic refresh is paused because the server rejected the key, so repeated attempts do not get this device banned. Edit the server to fix the key, or refresh to try again."
        case .ipBanned:
            "Automatic refresh is paused because the server has temporarily blocked this network address after too many failed key attempts, possibly by another client. The key may be fine. Refresh to try again once the block ends."
        }
    }
}

struct SessionStatusSection: View {
    let session: ServerSession
    let scope: RefreshScope

    var body: some View {
        if session.failure(for: scope) != nil || session.pauseReason != nil {
            Section {
                SessionStatusMessages(session: session, scope: scope)
            }
        }
    }
}

struct SessionStatusBanner: View {
    let session: ServerSession
    let scope: RefreshScope

    var body: some View {
        if session.failure(for: scope) != nil || session.pauseReason != nil {
            VStack(alignment: .leading, spacing: 8) {
                SessionStatusMessages(session: session, scope: scope)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: BoardStyle.cornerRadius))
        }
    }
}

private struct SessionStatusMessages: View {
    let session: ServerSession
    let scope: RefreshScope

    var body: some View {
        if let failure = session.failure(for: scope) {
            ErrorBanner(error: failure)
        }
        if let reason = session.pauseReason {
            Label {
                Text(reason.pausedNote)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: reason.symbol)
                    .foregroundStyle(.red)
            }
            .padding(.vertical, 4)
        }
    }
}

struct ErrorBanner: View {
    let error: APIError

    var body: some View {
        Label {
            Text(error.userMessage)
                .font(.callout)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 4)
    }
}

struct ManualRefreshHint: View {
    var body: some View {
        Label {
            Text("Automatic refresh is off — pull to refresh or press Refresh.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "pause.circle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct ElapsedText: View {
    let since: Date
    let text: (String) -> Text

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            text(ElapsedTime.text(from: since, to: context.date))
        }
    }
}

struct SavedDataNote: View {
    let savedAt: Date
    let refreshesAutomatically: Bool

    var body: some View {
        Label {
            ElapsedText(since: savedAt) { elapsed in
                if refreshesAutomatically {
                    Text("Showing data saved \(elapsed) ago while the server is loaded.")
                } else {
                    Text("Showing data saved \(elapsed) ago. Automatic refresh is off — pull to refresh or press Refresh.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct RefreshFooter: View {
    let lastRefresh: Date?
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isRefreshing {
                ProgressView().controlSize(.small)
            }
            if let lastRefresh {
                ElapsedText(since: lastRefresh) { Text("Updated \($0) ago") }
            } else if !isRefreshing {
                Text("Not refreshed yet")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct DemoBadge: View {
    var body: some View {
        Text("Demo")
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.purple.opacity(0.18), in: .capsule)
            .foregroundStyle(.purple)
    }
}

struct StateBadge: View {
    let state: CredentialState

    var body: some View {
        Label {
            Text(state.label)
        } icon: {
            Image(systemName: state.symbol)
        }
        .font(.caption.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .foregroundStyle(state.color)
    }
}

struct StateChip: View {
    let state: CredentialState

    var body: some View {
        Label {
            Text(state.label)
        } icon: {
            Image(systemName: state.symbol)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(state.color.opacity(0.16), in: .capsule)
        .foregroundStyle(state.color)
    }
}

enum ResetClock {
    static func format(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Date.FormatStyle {
        if calendar.isDate(date, inSameDayAs: now) {
            return .dateTime.hour().minute()
        }
        if abs(date.timeIntervalSince(now)) < 6 * 86_400 {
            return .dateTime.weekday(.abbreviated).hour().minute()
        }
        return .dateTime.month(.abbreviated).day().hour().minute()
    }

    static func text(_ date: Date) -> Text {
        Text(date, format: format(date))
    }
}

struct ResetNote: View {
    let resetsAt: Date

    var body: some View {
        if resetsAt > .now {
            Text("Resets \(ResetClock.text(resetsAt)) · in \(Text(resetsAt, style: .relative))")
        } else {
            Text("Window reset at \(ResetClock.text(resetsAt)); waiting for a new sample")
        }
    }
}

struct CooldownNote: View {
    let until: Date

    var body: some View {
        Label {
            Text("Cooling down until \(ResetClock.text(until)) · in \(Text(until, style: .relative))")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "hourglass")
        }
        .foregroundStyle(.orange)
    }
}

struct QuotaBarRow: View {
    let bar: QuotaBar
    let provider: String
    var compact = false

    var body: some View {
        let now = Date.now
        let remaining = bar.remainingPercent(at: now)
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                bar.title
                    .font(.caption.weight(.medium))
                if bar.isFromProvider {
                    ProviderSourceMark(sampledAt: bar.sampledAt)
                }
                if bar.isAtLimit(at: now) {
                    Text("At limit")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 4)
                Group {
                    if bar.startsOnUse(provider: provider, at: now) {
                        Text("Starts on use, \(HeadroomStyle.percentText(100)) left")
                    } else {
                        HeadroomStyle.remainingText(remaining)
                    }
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(remaining == nil ? .secondary : HeadroomStyle.color(forRemaining: remaining))
            }
            RemainingBar(remainingPercent: remaining, height: compact ? 5 : 6)
            if let resetsAt = bar.resetsAt {
                ResetNote(resetsAt: resetsAt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProviderSourceMark: View {
    let sampledAt: Date?

    var body: some View {
        Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .help(helpText)
            .accessibilityLabel(helpText)
    }

    private var helpText: Text {
        if let sampledAt {
            Text("Checked with the provider \(ElapsedTime.text(from: sampledAt, to: .now)) ago")
        } else {
            Text("Checked with the provider")
        }
    }
}

struct NoFiveHourWindowRow: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(QuotaWindow.session5h.label)
                .font(.caption.weight(.medium))
            Spacer(minLength: 4)
            Text("No 5-hour window running")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ModelCooldownNote: View {
    let cooldown: ModelCooldown

    var body: some View {
        Label {
            Group {
                if let until = cooldown.until, until > .now {
                    Text("\(cooldown.model) cooling down until \(ResetClock.text(until)) · in \(Text(until, style: .relative))")
                } else {
                    Text("\(cooldown.model) cooling down")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "hourglass")
        }
        .foregroundStyle(.orange)
    }
}

struct DisplayName: View {
    let profile: ServerProfile

    var body: some View {
        if profile.isDemo {
            Text("Demo server")
        } else {
            Text(verbatim: profile.name)
        }
    }
}

private struct AutoRefreshID<Target: Hashable>: Hashable {
    var target: Target
    var interval: TimeInterval
    var repeats: Bool
    var isInForeground: Bool
}

private struct AutoRefreshModifier<Target: Hashable>: ViewModifier {
    let interval: TimeInterval
    let target: Target
    let repeats: Bool
    let action: @MainActor () async -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: AutoRefreshID(target: target, interval: interval, repeats: repeats, isInForeground: scenePhase != .background)) {
            guard scenePhase != .background else { return }
            await AutoRefreshLoop.run(refreshesAutomatically: repeats, interval: interval, refresh: action)
        }
    }
}

extension View {
    func autoRefresh<Target: Hashable>(
        every interval: TimeInterval,
        target: Target,
        repeats: Bool,
        perform action: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(AutoRefreshModifier(interval: interval, target: target, repeats: repeats, action: action))
    }
}
