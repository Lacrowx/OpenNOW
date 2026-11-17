import AVFoundation
import AVKit
import Combine
import GameController
import SwiftUI
import UIKit

/// tvOS stream screen: native NVST video with a status overlay and an in-stream menu.
struct TVStreamerView: View {
    @StateObject private var coordinator: TVStreamCoordinator
    @EnvironmentObject private var store: OpenNOWStore

    init(make: @escaping @MainActor () -> TVStreamCoordinator) {
        _coordinator = StateObject(wrappedValue: make())
    }

    var body: some View {
        TVStreamHost(coordinator: coordinator, accent: store.settings.uiAccent)
            .ignoresSafeArea()
            .onAppear {
                coordinator.onEndSession = { [store] in Task { await store.endSession() } }
                coordinator.start()
            }
            .onDisappear { coordinator.stop() }
    }
}

private struct TVStreamHost: UIViewControllerRepresentable {
    let coordinator: TVStreamCoordinator
    /// The overlay is hosted on its own, outside the app's environment.
    let accent: UIAccent
    /// Lets a preview show artwork in place of the video.
    var transparent = false

    func makeUIViewController(context: Context) -> TVStreamHostController {
        TVStreamHostController(coordinator: coordinator, accent: accent, transparent: transparent)
    }

    func updateUIViewController(_ controller: TVStreamHostController, context: Context) {}
}

/// `GCEventViewController` keeps controller and remote buttons away from UIKit for the whole
/// stream, so B or Back reach the game or the stream menu instead of leaving the app.
private final class TVStreamHostController: GCEventViewController {
    private let coordinator: TVStreamCoordinator
    private let overlay: UIHostingController<TVStreamOverlay>
    private let transparent: Bool
    private var displayCriteriaObserver: AnyCancellable?

    init(coordinator: TVStreamCoordinator, accent: UIAccent, transparent: Bool) {
        self.coordinator = coordinator
        self.transparent = transparent
        overlay = UIHostingController(rootView: TVStreamOverlay(coordinator: coordinator, accent: accent))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = transparent ? .clear : .black
        view.layer.addSublayer(coordinator.displayLayer)
        addChild(overlay)
        overlay.view.backgroundColor = .clear
        overlay.view.frame = view.bounds
        overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay.view)
        overlay.didMove(toParent: self)
        controllerUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The display manager belongs to the window, which exists only once the view is on screen.
        displayCriteriaObserver = coordinator.$displayCriteria.sink { [weak self] criteria in
            guard let manager = self?.view.window?.avDisplayManager else { return }
            manager.preferredDisplayCriteria = criteria
            tvStreamDebug("[TVStream] display criteria \(criteria == nil ? "cleared" : "set") matchContent=\(manager.isDisplayCriteriaMatchingEnabled)")
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayCriteriaObserver = nil
        view.window?.avDisplayManager.preferredDisplayCriteria = nil
    }

    /// The Siri Remote's buttons still arrive here; game controllers stay with GameController.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { coordinator.remotePressed(press.type) }
        super.pressesBegan(presses, with: event)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        coordinator.displayLayer.frame = view.bounds
        CATransaction.commit()
    }
}

private struct TVStreamOverlay: View {
    @ObservedObject var coordinator: TVStreamCoordinator
    let accent: UIAccent

    var body: some View {
        ZStack {
            if coordinator.failed || coordinator.menuVisible {
                TVStreamMenuPanel(coordinator: coordinator)
                    .transition(.opacity)
            } else if !coordinator.videoActive {
                TVStreamConnectingView(coordinator: coordinator)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) { if !coordinator.failed { TVControllerNotice(videoActive: coordinator.videoActive) } }
        .overlay(alignment: coordinator.statsPosition.alignment) {
            // The menu shows the same figures, and the strip would lie over it.
            if coordinator.statsVisible, coordinator.videoActive, !coordinator.failed, !coordinator.menuVisible,
               coordinator.showsClock || !coordinator.hudItems.isEmpty { statsHUD }
        }
        .foregroundStyle(.white)
        .environment(\.openNowAccent, accent)
        .animation(.easeOut(duration: TVConsoleTheme.focusDuration), value: coordinator.failed || coordinator.menuVisible)
        .animation(.easeOut(duration: TVConsoleTheme.enterDuration), value: coordinator.videoActive)
    }

    /// One line of the figures chosen in Settings, drawn as the shell's status pill, inside the
    /// TV's title-safe area.
    private var statsHUD: some View {
        HStack(spacing: 16) {
            if coordinator.showsClock {
                TimelineView(.everyMinute) { Text($0.date.formatted(date: .omitted, time: .shortened)) }
                if !coordinator.hudItems.isEmpty { seam }
            }
            ForEach(Array(coordinator.hudItems.enumerated()), id: \.offset) { index, item in
                if index > 0 { seam }
                Text(item)
            }
        }
        .font(TVConsoleTheme.mono(15))
        .monospacedDigit()
        .foregroundStyle(TVConsoleTheme.label)
        .lineLimit(1)
        .padding(.horizontal, 22)
        .frame(height: 46)
        .tvConsoleGlass(radius: 23, strong: true)
        .padding(.horizontal, 80)
        .padding(.top, 60)
    }

    private var seam: some View {
        Rectangle().fill(TVConsoleTheme.seam).frame(width: 1, height: 18)
    }
}

/// Shown until the first frame: the queue screen's layout at its last step, so the hand-off
/// from the queue to the stream reads as one screen. Nothing on it takes focus; Back on the
/// remote, or holding Options on a controller, opens the stream menu as during play.
private struct TVStreamConnectingView: View {
    @ObservedObject var coordinator: TVStreamCoordinator
    /// Only for the hint's button symbol.
    @StateObject private var input = TVConsoleInput()
    @Environment(\.openNowAccent) private var accent

    /// A session past the queue with a rig ready to stream is at the rail's last step.
    private static let stage = TVConsoleLaunchStage(sessionStatus: 2, isPastQueue: true,
                                                    queuePosition: nil, queuePaused: false)

    var body: some View {
        TVConsoleLaunchStageView(
            game: coordinator.session.game,
            status: coordinator.status, tone: accent.color,
            eyebrow: "Starting your session",
            headline: Self.stage.headline,
            detail: Self.stage.detail,
            stage: Self.stage
        ) {
            TVConsoleRigCard(session: coordinator.session)
        } actions: {
            HStack(spacing: 22) {
                HStack(spacing: 10) {
                    TVConsoleGlyph(button: input.hasGamepad ? .options : .back)
                    Text(input.hasGamepad ? "Hold for the stream menu" : "Stream menu")
                        .font(TVConsoleTheme.display(17, weight: 800))
                        .foregroundStyle(TVConsoleTheme.label)
                }
                if !coordinator.detail.isEmpty {
                    Rectangle().fill(TVConsoleTheme.seam).frame(width: 1, height: 22)
                    // The handshake step or the requested video, for telling a stall apart.
                    Text(coordinator.detail.uppercased())
                        .font(TVConsoleTheme.mono(14))
                        .tracking(1.4)
                        .foregroundStyle(TVConsoleTheme.textMuted)
                        .lineLimit(1)
                }
            }
            .frame(height: 72)
        }
        .environmentObject(input)
        .onAppear { input.start() }
        .onDisappear { input.stop() }
    }
}

#if DEBUG
extension TVStreamerView {
    /// `--opennow-stream-menu-preview`: the stream menu over game artwork. `=failed` shows the
    /// failed-stream panel, `=confirm` the question before ending the session, `=connecting` the
    /// screen shown until the first frame, `=hud` the stats strip over the game.
    static func menuPreview(state: String) -> some View {
        TVStreamMenuPreview(state: state)
    }
}

private struct TVStreamMenuPreview: View {
    let state: String

    @EnvironmentObject private var store: OpenNOWStore
    @StateObject private var coordinator: TVStreamCoordinator

    init(state: String) {
        self.state = state
        let game = OpenNOWStore.debugStorePreviewGames[0]
        var session = ActiveSession(id: "menu-preview", game: game, startedAt: .now, status: 2,
            queuePosition: nil, seatSetupStep: nil, serverIp: nil, mediaIp: nil, mediaPort: 0,
            signalingServer: nil, signalingUrl: nil, iceServers: [], zone: "EU Central",
            streamingBaseUrl: "", clientId: "preview", deviceId: "preview", adState: nil)
        session.gpuType = "RTX 4080"
        _coordinator = StateObject(wrappedValue: TVStreamCoordinator(session: session, settings: .default,
            membershipTier: nil, sessionHistory: nil, onStatsOverlayChange: { _ in }, onRuntimeSample: { _ in },
            onTransportStable: {}, onStreamTermination: { _ in }, onTransportFailure: {}, onClose: {},
            onRetry: state == "failed" ? {} : nil))
    }

    var body: some View {
        TVStreamHost(coordinator: coordinator, accent: store.settings.uiAccent, transparent: true)
            // An overlay of the canvas, so the aspect-filled artwork never sizes the screen.
            .background {
                Color.black.overlay {
                    if let url = OpenNOWStore.debugStorePreviewGames[0].heroImageUrl.flatMap(URL.init(string:)) {
                        CachedRemoteImage(url: url, targetPixelSize: 1920) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.black
                        } failure: {
                            Color.black
                        }
                    }
                }
                .clipped()
            }
            .ignoresSafeArea()
        .onAppear {
            guard state != "connecting" else { return }
            coordinator.installMenuPreview(failed: state == "failed")
            switch state {
            case "confirm":
                coordinator.menuItems.indices.dropFirst().forEach { _ in coordinator.handleMenu(.down) }
                coordinator.handleMenu(.activate)
            case "hud":
                coordinator.handleMenu(.activate) // Resume
            default:
                break
            }
        }
    }
}
#endif
