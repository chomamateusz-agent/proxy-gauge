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
        let failure = session.failure(for: scope)
        if failure != nil || session.pauseReason != nil {
            Section {
                if let failure {
                    ErrorBanner(error: failure)
                }
                if let reason = session.pauseReason {
                    Label {
                        Text(reason.pausedNote)
                            .font(.callout)
                    } icon: {
                        Image(systemName: reason.symbol)
                            .foregroundStyle(.red)
                    }
                    .padding(.vertical, 4)
                }
            }
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

struct RefreshFooter: View {
    let lastRefresh: Date?
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isRefreshing {
                ProgressView().controlSize(.small)
            }
            if let lastRefresh {
                Text("Updated \(Text(lastRefresh, style: .relative)) ago")
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

struct QuotaBarRow: View {
    let bar: QuotaBar

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(bar.window.label)
                    .font(.caption.weight(.medium))
                Spacer()
                if let used = bar.usedPercent {
                    Text("\(HeadroomStyle.percentText(used)) used")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(HeadroomStyle.color(forUsed: used))
                } else {
                    Text("Unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            UsageBar(usedPercent: bar.usedPercent, height: 6)
            if let resetsAt = bar.resetsAt {
                Group {
                    if resetsAt > .now {
                        Text("Resets in \(Text(resetsAt, style: .relative))")
                    } else {
                        Text("Reset time passed; waiting for a new sample")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
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
    var isInForeground: Bool
}

private struct AutoRefreshModifier<Target: Hashable>: ViewModifier {
    let interval: TimeInterval
    let target: Target
    let action: @MainActor () async -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: AutoRefreshID(target: target, interval: interval, isInForeground: scenePhase != .background)) {
            guard scenePhase != .background else { return }
            while !Task.isCancelled {
                await action()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
}

extension View {
    func autoRefresh<Target: Hashable>(every interval: TimeInterval, target: Target, perform action: @escaping @MainActor () async -> Void) -> some View {
        modifier(AutoRefreshModifier(interval: interval, target: target, action: action))
    }
}
