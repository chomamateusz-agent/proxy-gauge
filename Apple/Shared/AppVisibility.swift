import SwiftUI
#if os(macOS)
import AppKit
import Combine
#endif

extension View {
    func tracksAppVisibility(_ isVisible: Binding<Bool>) -> some View {
        modifier(AppVisibilityTracker(isVisible: isVisible))
    }
}

private struct AppVisibilityTracker: ViewModifier {
    @Binding var isVisible: Bool
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onAppear { isVisible = MacAppVisibility.isOnScreen }
            .onReceive(MacAppVisibility.changes) { _ in isVisible = MacAppVisibility.isOnScreen }
        #else
        content
            .onChange(of: scenePhase, initial: true) { _, phase in isVisible = phase != .background }
        #endif
    }
}

#if os(macOS)
@MainActor
enum MacAppVisibility {
    private static let names: [Notification.Name] = [
        NSApplication.didBecomeActiveNotification,
        NSApplication.didResignActiveNotification,
        NSApplication.didHideNotification,
        NSApplication.didUnhideNotification,
        NSApplication.didChangeOcclusionStateNotification,
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification
    ]

    static var changes: AnyPublisher<Notification, Never> {
        Publishers.MergeMany(names.map { NotificationCenter.default.publisher(for: $0) })
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    static var isOnScreen: Bool {
        let application = NSApplication.shared
        guard !application.isHidden else { return false }
        return application.windows.contains { window in
            window.canBecomeMain
                && window.isVisible
                && !window.isMiniaturized
                && (application.isActive || window.occlusionState.contains(.visible))
        }
    }
}
#endif
