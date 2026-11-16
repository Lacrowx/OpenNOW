import GameController
import SwiftUI

/// Whether a game controller that the stream can use is connected. Only extended gamepads send
/// input, so the Siri Remote alone cannot play.
@MainActor
final class TVControllerMonitor: ObservableObject {
    static let queueMessage = "A game controller is needed to play. Connect one before the stream starts."
    static let streamMessage = "A game controller is needed to play. Press Back on the remote to open the menu."

    /// How long the notice stays once the video is running.
    static let streamingSeconds: TimeInterval = 10

    @Published private(set) var hasGamepad = TVControllerMonitor.currentlyHasGamepad()
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hasGamepad = Self.currentlyHasGamepad() }
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private static func currentlyHasGamepad() -> Bool {
        #if DEBUG
        // The simulator presents its remote as a gamepad; this shows the notice there.
        if ProcessInfo.processInfo.arguments.contains("--opennow-no-controller-preview") { return false }
        #endif
        return GCController.controllers().contains { $0.extendedGamepad != nil }
    }

    /// Shown while connecting for as long as it is needed; once the video runs, only for the first seconds.
    nonisolated static func shouldShow(hasGamepad: Bool, videoActive: Bool, secondsSinceVideo: TimeInterval) -> Bool {
        guard !hasGamepad else { return false }
        return !videoActive || secondsSinceVideo < streamingSeconds
    }
}

/// A single line saying a controller is needed. Used on the queue screen and over the stream.
struct TVControllerNotice: View {
    var message = TVControllerMonitor.streamMessage
    var videoActive = false
    @StateObject private var monitor = TVControllerMonitor()
    @State private var expired = false

    var body: some View {
        Group {
            if TVControllerMonitor.shouldShow(hasGamepad: monitor.hasGamepad, videoActive: videoActive,
                                              secondsSinceVideo: expired ? .infinity : 0) {
                Text(message)
                    .font(TVConsoleTheme.display(20, weight: 700))
                    .foregroundStyle(TVConsoleTheme.yellow)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(TVConsoleTheme.glassStrong, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: 720)
                    .padding(60)
            }
        }
        // On the Group, so a reconnect (video stops, then runs again) shows the notice again.
        .task(id: videoActive) {
            guard videoActive else { expired = false; return }
            try? await Task.sleep(for: .seconds(TVControllerMonitor.streamingSeconds))
            expired = true
        }
    }
}
